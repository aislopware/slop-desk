# Pan-Only Infinite Canvas — Implementation Spec of Record

Status: spec of record. Replaces the split-tiling workspace with a pan-only infinite canvas. Built against the actual code (paths + line numbers verified). The governing physical constraint and the architectural seam are both load-bearing and both preserved:

- **Physical**: a libghostty terminal surface sizes itself from its hosting view's `bounds × contentsScale` in **points** and pins `layer.bounds == view.bounds` (`GhosttyTerminalView.layout()`), with mouse coords mapped 1:1 with a y-flip. Therefore the camera is a **pure translate** — never a `scaleEffect`/`CGAffineTransform` on any ancestor of a surface — and a pane's on-screen size always equals its canvas-space size (resize = change the frame → existing reflow path).
- **Architectural** (docs/22): tree-of-intent (pure value types) + table-of-liveness (`WorkspaceStore.registry` + `reconcile()`). The invariant is unchanged:
  ```
  Set(registry.keys) == Set(workspace.tabs.flatMap { $0.<canvas>.allIDs() })
  ```
  Only the *source* of "all pane ids" changes from `PaneNode.allLeafIDs()` to `Canvas.allIDs()`. `reconcile()`, the registry, the video cap, `focusCoordinator`, and the debounced-save path are reused verbatim.

---

## 1. Decisions & rationale

**Model shape.** A `Tab`'s `root: PaneNode` (recursive `indirect enum` split tree) becomes `canvas: Canvas` — a flat value type `{ items: [CanvasItem], camera: CanvasCamera }`. Flat-not-recursive removes the only reason the hand-written discriminated `PaneNode+Codable` existed (recursive enum). Each `CanvasItem` carries the **same `PaneID`** (the registry/`reconcile`/`.id(PaneID)` join key is reused unchanged), a value `PaneSpec`, a `frame: CGRect` in canvas space (its width/height ARE the 1:1 on-screen size that drives the terminal host's `.frame` → `layout()` → reflow), and an explicit `z: Int`.

**Z-order representation.** **Explicit `z: Int` field** (NOT array order — diverging from proposals 2/3). Rationale: the codebase's persistence is byte-stable with `.sortedKeys` and the corrupt-file repair (`dedupingLeafIDs`/`map`) iterates tabs; an explicit `z` makes `items` array order irrelevant to rendering, so a re-mint, a dedup, or a future reorder can never silently change stacking. `raise(id)` is `z = maxZ + 1` (O(1) amortized). `reconcile()` diffs a `Set` of ids (`allLeafIDs()` → `Set`), so order never mattered to reconcile anyway. Rendering and focus iterate **z-ascending** (ties broken by `id` string) for total determinism; hit-test iterates z-descending.

**`zoomedPane` fate.** **Keep as a pure presentation flag; rename `zoomedPane → maximizedPane`.** Semantics: "render this one item full-viewport, ignore the camera/other items." This preserves the proven no-teardown property (same `.id(PaneID)`, registry untouched — exactly `PaneTreeView`'s zoom branch). It is *more* valuable on a sprawling canvas (a focus-mode escape hatch). The rename kills the dangerous ambiguity that "zoom" implies the scale we structurally forbid. The store op keeps the name `toggleZoom()` (a chord/menu word) but flips `maximizedPane`.

**New-pane placement.** Cascade + collision-nudge + clamp-into-view, anchored to the focused pane (NSWindow `cascadeTopLeft` convention, ~28pt down-right), then a store-level **in-view guarantee**: after placement, if the new item does not intersect the viewport, pan the camera to center it. Without zoom-to-fit, a new pane that lands off-screen is invisible — so placement + `centered(on:)` together guarantee the new pane is always at least partially visible, focused, and raised. Pure `CanvasGeometry.placement(...)` returns the frame; the store composes `adding` + `centered`.

**Culling policy.** **Kind-aware.** Terminal/`claudeCode` panes are **never culled** (kept mounted, translated off-viewport by the camera offset). Reason from the libghostty research: removing a terminal host view closes the surface; on revisit a fresh surface replays the retained byte ring (capped 256KB), which can show a **stale frame for an alt-screen TUI** (vim/tmux) until the host repaints — which on a static screen may be never. Keeping them mounted (the OS occludes off-screen views; `setFocus(true)` stays, so they repaint on pan-back with zero replay cost) trades a bounded number of idle Metal surfaces (acceptable at the "few dozen panes" scale) for zero stale-frame risk. **`.remoteGUI` (video) panes ARE culled** off-viewport (plus margin), where culling is beneficial (frees a `liveVideoCap` slot) and the `.onAppear/.onDisappear` activate/deactivate gate is built for it. The focused pane is never culled regardless of kind. This requires one defensive store change so the video-cap teardown decision means "off-screen" not just "off active tab" (§5 `isPaneVisible`), because on a canvas an off-viewport pane is still `isPaneOnActiveTab == true`.

**Migration strategy.** Schema bumps **v1 → v2**, a **wire-shape change** (`Tab.root` → `Tab.canvas`) that `WorkspaceSchemaMigration` cannot do (it migrates an *already-decoded* value — its own doc-comment, `WorkspaceSchemaMigration.swift:18-26`, flags the pre-decode raw-JSON branch as the next step). So `WorkspacePersistence.load()` gets a **pre-decode `schemaVersion` peek**: a v1/v0 payload is decoded against a **quarantined legacy `PaneNode`** shape, then each tab's tree is flattened to canvas items by running the **real `LayoutSolver.solve`** at a nominal viewport to seed each leaf's frame (so a migrated user's panes appear roughly where they were tiled), preserving every `PaneID`/`TabID`/`PaneSpec`/`maximizedPane`. `PaneNode`, `PaneNode+Codable`, and `LayoutSolver` are **retained but quarantined** (`internal`, `Legacy/` group, referenced only by migration) — deleting them would lose the proven frame-seeder. Lossless by construction; never discards on a recoverable shape; the existing `.corrupt` sidecar covers hard failure.

---

## 2. Data model — exact Swift

New file `Sources/AislopdeskClientUI/Workspace/Domain/Canvas.swift`. `import Foundation` + `import CoreGraphics` only (Domain purity — no SwiftUI, no AislopdeskClient — same as `LayoutSolver.swift`/`FocusResolver.swift`).

```swift
import Foundation
import CoreGraphics

// MARK: - The pan-only camera

/// The viewport's pan offset over one tab's infinite plane: the **canvas-space point shown at the
/// viewport's top-left** (screen = canvas − origin, a rigid translate). Pan-only by construction —
/// there is NO scale field, so a whole-board zoom is unrepresentable. The libghostty surface sizes
/// itself from its hosting view's `bounds × contentsScale` in POINTS and pins
/// `layer.bounds == view.bounds` (GhosttyTerminalView.layout()); any scale desyncs that and breaks
/// the points-with-y-flip 1:1 mouse mapping. Omitting the field is the strongest enforcement.
public struct CanvasCamera: Codable, Sendable, Equatable {
    /// Canvas-space point at the viewport's top-left.
    public var origin: CGPoint
    public init(origin: CGPoint = .zero) { self.origin = origin }
    public static let zero = CanvasCamera(origin: .zero)
}

// MARK: - One item on the plane

/// One pane placed on a tab's infinite plane (replaces a `PaneNode` leaf). Pure value type.
public struct CanvasItem: Identifiable, Codable, Sendable, Equatable {
    /// SAME PaneID join key — `reconcile`/registry/`.id(PaneID)` all reuse it verbatim.
    public let id: PaneID
    /// Pure intent (kind/title/endpoint/video). Unchanged value type.
    public var spec: PaneSpec
    /// Canvas-space rect; origin may be negative. width/height = the pane's 1:1 size, which drives the
    /// terminal host's `.frame` → `layout()` → `setPixelSize` → cols×rows reflow (the existing path,
    /// no new resize API). Always finite, size ≥ `Canvas.minItemSize`.
    public var frame: CGRect
    /// Explicit z-order; higher == frontmost (focused / last-dragged on top).
    public var z: Int
    public init(id: PaneID, spec: PaneSpec, frame: CGRect, z: Int) {
        self.id = id; self.spec = spec; self.frame = frame; self.z = z
    }
}

// MARK: - The free 2D plane (replaces PaneNode as a Tab's layout model)

/// One ``Tab``'s infinite plane. Pure value type, the persistence format, holding no live object —
/// every mutation is a pure function returning a NEW `Canvas`.
///
/// ### Invariants (held by every op; enforced on decode, §4)
/// - **Unique ids**: `items.map(\.id)` has no duplicates (decode keeps raw; `load()` re-mints via
///   `dedupingItemIDs`, the registry being keyed 1:1 by PaneID).
/// - **Finite, on-floor frames**: every `frame` is finite and has size ≥ `minItemSize`.
/// - **Non-empty**: a persisted live tab has ≥ 1 item (the last `removing(_:)` returns nil → the
///   store closes the tab, same contract as `PaneNode.closing → nil`).
/// - **Pan-only camera**: `camera` is a translation; there is no scale field.
public struct Canvas: Codable, Sendable, Equatable {
    /// All items. Array order is NOT z-order — `CanvasItem.z` is. (Keeps order irrelevant to render.)
    public var items: [CanvasItem]
    /// The pan offset (view-state that also persists, debounced, like fractions did).
    public var camera: CanvasCamera
    public init(items: [CanvasItem], camera: CanvasCamera = .zero) {
        self.items = items; self.camera = camera
    }
}

public extension Canvas {
    /// Minimum item size in canvas points == today's `PaneTreeView.minLeaf` (160×120) so cols/rows
    /// never collapse below a usable grid.
    static let minItemSize = CGSize(width: 160, height: 120)
    /// Default size for a brand-new pane (a comfortable shell).
    static let defaultItemSize = CGSize(width: 640, height: 420)
    /// Cascade step for new-pane placement (one title-bar + margin; NSWindow convention).
    static let cascadeStep: CGFloat = 28
    /// Off-viewport overscan kept mounted so a video pane about to pan in is already warm.
    static let cullMargin: CGFloat = 600
}
```

### Change to `Tab` (`Sources/AislopdeskClientUI/Workspace/Domain/Tab.swift`)

```swift
public struct Tab: Identifiable, Codable, Sendable, Equatable {
    public let id: TabID
    public var name: String
    public var canvas: Canvas                 // was: root: PaneNode
    public var focusedPane: PaneID            // unchanged — always a valid item id
    /// nil = normal canvas; non-nil = that item is maximized to fill the viewport (a pure
    /// presentation flag; renders the one item full-bleed, ignores camera, no model surgery).
    public var maximizedPane: PaneID?         // was: zoomedPane

    public init(id: TabID = TabID(), name: String, canvas: Canvas,
                focusedPane: PaneID, maximizedPane: PaneID? = nil) {
        self.id = id; self.name = name; self.canvas = canvas
        self.focusedPane = focusedPane; self.maximizedPane = maximizedPane
    }
}

public extension Tab {
    /// Single-item tab: one item at the canvas origin, default size, z=0, focused, not maximized.
    static func make(kind: PaneKind, title: String, endpoint: Endpoint? = nil) -> Tab {
        let paneID = PaneID()
        let spec = PaneSpec(kind: kind, title: title, endpoint: endpoint)
        let item = CanvasItem(id: paneID, spec: spec,
                              frame: CGRect(origin: .zero, size: Canvas.defaultItemSize), z: 0)
        return Tab(name: title, canvas: Canvas(items: [item]), focusedPane: paneID)
    }
}
```

`Workspace` is unchanged in shape except `currentSchemaVersion` 1 → 2 (`Workspace.swift:36`). `Workspace.normalizingTabFocus()` (`Workspace.swift:79`) changes `copy.tabs[i].root.allLeafIDs()` → `copy.tabs[i].canvas.allIDs()`.

---

## 3. Pure ops

New files `Sources/AislopdeskClientUI/Workspace/Domain/Canvas+Ops.swift` (queries + mutations + camera/arrange) and `Sources/AislopdeskClientUI/Workspace/Domain/CanvasGeometry.swift` (pure static geometry: resize/placement/screenRect/culling). All on `Canvas`, each returns a new value or a pure read.

### Queries (drive reconcile + coupling — replace PaneNode reads)
```swift
public extension Canvas {
    func allIDs() -> [PaneID]                  // items sorted z-ASC (ties by id) — DRIVES reconcile; replaces allLeafIDs()
    var itemCount: Int { items.count }         // replaces leafCount
    func contains(_ id: PaneID) -> Bool        // any item has id
    func spec(for id: PaneID) -> PaneSpec?     // replaces PaneNode.spec(for:)
    func frame(of id: PaneID) -> CGRect?       // canvas-space frame, or nil
    func item(_ id: PaneID) -> CanvasItem?     // lookup
    var maxZ: Int                              // items.map(\.z).max() ?? -1
    func framesByID() -> [PaneID: CGRect]      // for SolvedLayout (focus reuse)
    func hitTest(_ point: CGPoint) -> PaneID?  // items sorted z-DESC, first whose frame contains point (canvas space)
    func dedupingItemIDs(seen: inout Set<PaneID>) -> Canvas  // re-mint duplicate ids (load-time repair; port of dedupingLeafIDs)
}
```

### Structural mutations (replace split/setFractions/closing)
```swift
public extension Canvas {
    /// Append a NEW item of `spec` (z = maxZ+1, frontmost), placed near `near` via
    /// `CanvasGeometry.placement(...)`; returns (newCanvas, newID). Replaces `splitting`.
    func adding(_ spec: PaneSpec, near: PaneID?, viewport: CGSize,
                size: CGSize = Canvas.defaultItemSize) -> (Canvas, PaneID)
    /// Remove `id`; returns nil iff it was the LAST item (tab empties — same nil contract as
    /// PaneNode.closing). Surviving z preserved.
    func removing(_ id: PaneID) -> Canvas?
    /// frame.origin += delta, clamped finite. (chrome drag-to-move commit) No raise (store does it).
    func moving(_ id: PaneID, by delta: CGSize) -> Canvas
    /// frame.origin = point, clamped finite.
    func moving(_ id: PaneID, to origin: CGPoint) -> Canvas
    /// Set frame, clamped so size ≥ minItemSize and finite. (corner/edge resize commit)
    func resizing(_ id: PaneID, to frame: CGRect) -> Canvas
    /// z = maxZ+1 (no-op if already top). bring-to-front.
    func raising(_ id: PaneID) -> Canvas
    /// Spec edit in place (rename / fill endpoint). No-op if absent. (port of updatingSpec)
    func updatingSpec(_ id: PaneID, _ transform: (inout PaneSpec) -> Void) -> Canvas
}
```

### Camera / arrange (pure)
```swift
public extension Canvas {
    func panned(by delta: CGSize) -> Canvas                    // camera.origin += delta. NO /scale term.
    func camera(_ camera: CanvasCamera) -> Canvas             // replace camera (commit a live pan)
    func centered(on id: PaneID, viewport: CGSize) -> Canvas  // item center → viewport center; ALWAYS works
    func centeredOnAll(viewport: CGSize) -> Canvas            // center on bbox of all items (CANNOT shrink); identity if empty
    func tidied(gutter: CGFloat = 16, viewport: CGSize) -> Canvas  // pack into a uniform grid (cols≈ceil(sqrt(n))), z preserved, camera recentered
    func needsRecenter(viewport: CGSize) -> Bool              // true when NO item intersects the viewport (drives "Recenter")
}
```

### Pure static geometry (`CanvasGeometry`) — the `SplitContainer.applyingDelta` analogue
```swift
public enum ResizeAnchor: Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
}

public enum CanvasGeometry {
    /// Screen rect for a canvas frame under a camera (PURE TRANSLATE — width/height copied verbatim ⇒ 1:1).
    public static func screenRect(_ f: CGRect, camera: CanvasCamera) -> CGRect

    /// New frame while dragging `anchor` by `delta`: adjust the anchored edges, pin the opposite
    /// edge(s), floor width/height to `minSize`. Pure; unit-tested edge-by-edge over all 8 anchors.
    public static func resizing(_ frame: CGRect, anchor: ResizeAnchor, by delta: CGSize, minSize: CGSize) -> CGRect

    /// New-pane placement: seed at `near.origin + (cascade,cascade)` (else viewport center in canvas
    /// space); while a candidate overlaps any `existing` by >25% of its own area, step (cascade,cascade)
    /// (cap ~12 steps, then a free grid scan to guarantee termination). Returns a clean frame; the
    /// store separately composes `centered(on:)` for the in-view guarantee.
    public static func placement(near: CGRect?, existing: [CGRect], viewport: CGRect,
                                 size: CGSize, cascade: CGFloat = Canvas.cascadeStep) -> CGRect

    /// Items to MOUNT (pure culling, kind-aware): every non-remoteGUI item (terminals never culled —
    /// no stale-replay risk), the focused pane (never culled), and any remoteGUI item intersecting
    /// (viewport + margin). Pure → unit-tested with no view.
    public static func visibleItems(_ items: [CanvasItem], camera: CanvasCamera, viewport: CGSize,
                                    focused: PaneID?, margin: CGFloat = Canvas.cullMargin) -> [CanvasItem]

    /// The set of item ids whose frame intersects the viewport (NO margin, NO kind filter) — the
    /// video-cap "on screen" signal the store consumes (independent of the mount filter so terminals
    /// being kept mounted does not pollute it).
    public static func viewportMembers(_ items: [CanvasItem], camera: CanvasCamera, viewport: CGSize) -> Set<PaneID>
}
```

### SolvedLayout from a Canvas (FocusResolver reuse — resolver UNCHANGED)
`SolvedLayout`, `DividerHandle`, and `FocusResolver` are reused verbatim. `SolvedLayout`/`DividerHandle` are **extracted** to a new `Domain/SolvedLayout.swift` so the types survive independent of the quarantined `LayoutSolver`. Build the layout in **canvas space** (camera-independent → directional focus stable across pans; off-screen panes remain keyboard-navigable), `dividers: []`:

```swift
public extension Canvas {
    /// SolvedLayout for FocusResolver: canvas-space item frames, no dividers (divider concept gone).
    func solvedLayout() -> SolvedLayout {
        SolvedLayout(frames: framesByID(), dividers: [])
    }
}
```
`FocusResolver.neighbor(of:_:in:)` and `cycle(_:from:forward:)` consume only `frames` and work unchanged. Overlap ties (cascaded/raised panes) are already discriminated by `crossAxisOverlap` then `axialDistance`; identical-frame ties resolve to iteration order — made deterministic by feeding z-ascending order. No resolver edit.

---

## 4. Codable + schemaVersion v2 + the v1→v2 migration

### 4.1 Codable for the new types
`CanvasCamera`, `CanvasItem`, `Canvas` are flat (no recursion) → **synthesized `Codable` is safe** (`CGRect`/`CGPoint`/`CGSize` are Codable via CoreGraphics). The hand-written discriminated codec that `PaneNode+Codable` needed (recursive `indirect enum`) is no longer required.

Add ONE defensive `init(from:)`/`encode(to:)` on `Canvas` in `Sources/AislopdeskClientUI/Workspace/Domain/Canvas+Codable.swift` to enforce invariants on decode (mirroring `PaneNode+Codable`'s `children.count >= 2` guard), so corruption fails the decode → `load()` falls back cleanly:

```swift
extension Canvas {
    private enum CodingKeys: String, CodingKey { case items, camera }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawItems = try c.decode([CanvasItem].self, forKey: .items)
        let camera = try c.decodeIfPresent(CanvasCamera.self, forKey: .camera) ?? .zero
        guard !rawItems.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                debugDescription: "Canvas must have >= 1 item"))
        }
        // Sanitize: finite origin, size clamped ≥ minItemSize (a NaN/zero frame must never render).
        let sanitized = rawItems.map { var it = $0; it.frame = Canvas.sanitize(it.frame); return it }
        self.init(items: sanitized, camera: camera)   // dedupe of ids happens at load() (lossless re-mint)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(camera, forKey: .camera)
    }
    /// Finite origin; size = max(size, minItemSize). NaN/inf → minItemSize.
    static func sanitize(_ f: CGRect) -> CGRect
}
```

Wire shape (stable, `.sortedKeys`):
```json
"canvas": {
  "camera": { "origin": { "x": -120, "y": 40 } },
  "items": [
    { "id": { "raw": "<uuid>" }, "z": 0,
      "frame": { "origin": {"x":0,"y":0}, "size": {"width":640,"height":420} },
      "spec": { "kind": "terminal", "title": "Terminal" } }
  ]
}
```

### 4.2 schemaVersion
`Workspace.currentSchemaVersion = 2` (`Workspace.swift:36`).

### 4.3 Retaining legacy `PaneNode` (quarantined)
`PaneNode.swift`, `PaneNode+Codable.swift`, `LayoutSolver.swift` are **moved to `Sources/AislopdeskClientUI/Workspace/Legacy/`** and made `internal` (drop `public`). Referenced by **nothing** except the migration below. The structural mutation ops (`splitting`/`closing`/`settingFractions`) stay (they compile inside the legacy file) but are dead; only the decode + `allLeafIDs()` + `spec(for:)` + `LayoutSolver.solve` surface is exercised. Add a top-of-file doc: "LEGACY — v1 persistence decode + migration frame-seed ONLY; not used at runtime." `SplitAxis` (used by `DividerHandle`/`LayoutSolver`) stays with the legacy/solver code; `DividerHandle` moves to `Domain/SolvedLayout.swift` (it is part of `SolvedLayout`'s type, always `[]` now).

### 4.4 The v1→v2 migration (pre-decode raw-JSON peek)
New file `Sources/AislopdeskClientUI/Workspace/Legacy/WorkspaceV1Migration.swift`:

```swift
import Foundation
import CoreGraphics

/// The PRE-DECODE wire-reshape migration (the step WorkspaceSchemaMigration cannot do — see its
/// doc, lines 18-26). v1 persisted `Tab.root: PaneNode`; v2 persists `Tab.canvas: Canvas`. The v2
/// decoder cannot parse a v1 `root`, so we decode the LEGACY shape and reshape it. Pure + total.
enum WorkspaceV1Migration {
    /// Nominal canvas size each v1 tree is solved at to SEED item frames (panes land roughly where
    /// they were tiled).
    static let seedViewport = CGSize(width: 1280, height: 800)

    /// Peek schemaVersion off the raw object (do NOT full-decode).
    static func peekSchemaVersion(_ data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
    }

    /// If `data` is a v1/v0 payload, decode the legacy shape, reshape each tab → Canvas, return a
    /// CURRENT-shape Workspace (schemaVersion 2). nil if not a recognizable legacy payload.
    static func migrateIfLegacy(_ data: Data) -> Workspace? {
        guard let v = peekSchemaVersion(data), v < 2,
              let legacy = try? JSONDecoder().decode(LegacyWorkspaceV1.self, from: data) else { return nil }
        // v0 active-tab normalization folded in (port of upgradeV0toV1) on the way out.
        var ws = Workspace(schemaVersion: 2, tabs: legacy.tabs.map(reshape), activeTabID: legacy.activeTabID)
        let activeOK = ws.activeTabID.map { id in ws.tabs.contains { $0.id == id } } ?? false
        if !activeOK { ws.activeTabID = ws.tabs.first?.id }
        return ws
    }

    /// One legacy tab → a Canvas tab: solve the tree at `seedViewport`, emit each leaf at its solved
    /// rect (PRESERVING PaneID + spec), z = pre-order index. zoomedPane → maximizedPane (same flag).
    private static func reshape(_ t: LegacyTabV1) -> Tab {
        let solved = LayoutSolver.solve(t.root, in: seedViewport, minLeaf: Canvas.minItemSize)
        let items: [CanvasItem] = t.root.allLeafIDs().enumerated().compactMap { (z, id) in
            guard let spec = t.root.spec(for: id), let frame = solved.frames[id] else { return nil }
            return CanvasItem(id: id, spec: spec, frame: Canvas.sanitize(frame), z: z)
        }
        // v1 trees always have ≥1 leaf; guard total anyway.
        let safe = items.isEmpty
            ? [CanvasItem(id: t.focusedPane, spec: PaneSpec(kind: .terminal, title: t.name),
                          frame: CGRect(origin: .zero, size: Canvas.defaultItemSize), z: 0)]
            : items
        return Tab(id: t.id, name: t.name, canvas: Canvas(items: safe, camera: .zero),
                   focusedPane: t.focusedPane, maximizedPane: t.zoomedPane)
    }
}

// Legacy decode-only mirrors (the v1 wire shape; the live model never sees them).
private struct LegacyWorkspaceV1: Decodable { let schemaVersion: Int; let tabs: [LegacyTabV1]; let activeTabID: TabID? }
private struct LegacyTabV1: Decodable { let id: TabID; let name: String; let root: PaneNode
                                        let focusedPane: PaneID; let zoomedPane: PaneID? }
```

`WorkspacePersistence.load()` (`WorkspacePersistence.swift:91-117`) gains the pre-decode branch (the only change to that file besides `dedupingLeafIDs → dedupingItemIDs`):

```swift
public func load() -> Workspace {
    guard let data = try? Data(contentsOf: fileURL) else { return .defaultWorkspace() }

    // PRE-DECODE wire-reshape: a v1/v0 file's `root: PaneNode` can't decode into v2's `canvas`. Peek
    // the version; if legacy, reshape (solve the tree → seed item frames) BEFORE the v2 decode. Prefer
    // recovery over reset: try v2, then legacy, and only resetToDefault() when BOTH fail.
    let peeked = WorkspaceV1Migration.peekSchemaVersion(data)
    let decoded: Workspace?
    switch peeked {
    case .some(0), .some(1):
        decoded = WorkspaceV1Migration.migrateIfLegacy(data)
    case .some(2), .none:
        decoded = (try? JSONDecoder().decode(Workspace.self, from: data))
            ?? WorkspaceV1Migration.migrateIfLegacy(data)   // unversioned-but-v1-shaped fallback
    case .some:                                              // future (>2): unreadable by this build
        decoded = nil
    }
    guard let value = decoded else { return resetToDefault() }

    guard let migrated = WorkspaceSchemaMigration.migrate(value, from: value.schemaVersion) else {
        return resetToDefault()
    }
    var seen = Set<PaneID>()
    var repaired = migrated
    repaired.tabs = repaired.tabs.map { tab in
        var t = tab; t.canvas = t.canvas.dedupingItemIDs(seen: &seen); return t   // was: t.root.dedupingLeafIDs
    }
    return repaired.normalizingActiveTab().normalizingTabFocus()
}
```

`WorkspaceSchemaMigration.steps` keeps `[0: upgradeV0toV1]` (harmless; legacy files take the pre-decode branch). `migrate(value, from: value.schemaVersion)` with `value.schemaVersion == 2` is the identity fast path. **Lossless guarantees**: every v1 `PaneID`/`TabID` survives (focus/active-tab references stay valid); every `spec` (kind/title/endpoint/video) survives; `maximizedPane` carries `zoomedPane`; relative tiled adjacency is preserved (solved rects); sessions start idle.

---

## 5. WorkspaceStore — method-by-method change list

`reconcile()` (`WorkspaceStore.swift:634-725`) is byte-for-byte unchanged **except the one line** `allLeafIDs()` now reads `canvas.allIDs()` (and the autotype autotype-target line `:710`). Therefore the registry, video-cap accounting (`tearingDownVideo`/`hasFreeVideoSlot`/`liveVideoCap`/`videoPromotionGeneration`), `focusCoordinator`/`syncFocusCoordinator`, the debounced-save path (`scheduleSave`/`saveImmediately`/`saveGeneration`/`savingEnabled`), `quiesce`/`pauseAll`/`resumeAll` are **preserved verbatim**. Every new mutation ends in `reconcile()`, so the invariant `Set(registry.keys) == Set(allIDs)` holds after any op; `move/resize/raise/pan/center/tidy/commitCamera` leave the item *set* unchanged → reconcile is a registry no-op (save only); `addPane`/`closePane` change the set by exactly one.

### 5.1 Mechanical `.root` → `.canvas` reads
| Site | Was | Becomes |
|---|---|---|
| `isPaneOnActiveTab` :228 | `activeTab?.root.contains(id)` | `activeTab?.canvas.contains(id)` |
| `allLeafIDs()` :231-233 | `$0.root.allLeafIDs()` | `$0.canvas.allIDs()` |
| reconcile autotype :710 | `tabs.first?.root.allLeafIDs().first` | `tabs.first?.canvas.allIDs().first` |
| `spec(for:)` :820-825 | `tab.root.spec(for:)` | `tab.canvas.spec(for:)` |
| `tabID(owning:)` :836-838 | `$0.root.contains(id)` | `$0.canvas.contains(id)` |
| `isOnlyLeaf` :843-846 | `tab.root.allLeafIDs().count == 1` | `tab.canvas.itemCount == 1` (and `.contains`) |
| `neighbourForRefocus` :857-862 | `tab.root.allLeafIDs()` | `tab.canvas.allIDs()` (geometric branch unchanged) |
| `singleLeafWorkspace` :597-601 | `.leaf(paneID, spec)` | `Canvas(items: [CanvasItem(id:paneID, spec:spec, frame: origin+defaultItemSize, z:0)])` |

### 5.2 Removed
- `split(_:axis:kind:)` (:295-312) — replaced by `addPane`.
- `setFractions(tab:path:to:)` (:384-389) — dividers are gone.

### 5.3 Viewport reporting + video-cap defensiveness (NEW)
The store needs the viewport for placement/center/tidy and a true "on screen" signal for video teardown.

```swift
private var lastViewport: CGSize = CGSize(width: 1280, height: 800)   // last reported; nominal default
public func updateViewport(_ size: CGSize) { if size.width > 0, size.height > 0 { lastViewport = size } }

/// Ids the canvas reports as inside the viewport (no margin). View-only; never reconciles.
private var paneIDsInViewport: Set<PaneID> = []
public func updateViewportMembership(_ ids: Set<PaneID>) { paneIDsInViewport = ids }

/// On the active tab AND inside the reported viewport — the signal the video teardown re-check uses
/// instead of `isPaneOnActiveTab` (an off-viewport canvas pane is still on the active tab, so that
/// guard would never free its cap slot). Empty set / compact carousel / pre-report → falls back to
/// `isPaneOnActiveTab` so the non-canvas paths are byte-identical (no regression).
public func isPaneVisible(_ id: PaneID) -> Bool {
    guard isPaneOnActiveTab(id) else { return false }
    return paneIDsInViewport.isEmpty ? true : paneIDsInViewport.contains(id)
}
```
`PaneLeafView`'s debounced teardown guard (`PaneLeafView.swift:642`) changes `store.isPaneOnActiveTab(live.id)` → `store.isPaneVisible(live.id)`. The spurious-`.onDisappear` mitigation is intact (an in-viewport pane stays in the set → self-cancels); the empty-set fallback preserves terminal-only / tab-switch / pre-report behavior exactly.

### 5.4 New canvas mutations (each: pure op → reconcile)
```swift
/// Add a new pane of `kind` near the focused pane, focus + raise it, guarantee in-view. Replaces
/// split(). Connect-once inheritance copied from split() (terminal/claudeCode inherit endpoint).
public func addPane(kind: PaneKind) {
    guard let tabID = workspace.activeTabID else { return }
    let inherited: Endpoint? = (kind == .terminal || kind == .claudeCode)
        ? (workspace.activeTab?.focusedPane.flatMap { spec(for: $0)?.endpoint } ?? activePaneEndpoint) : nil
    let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind), endpoint: inherited)
    let viewport = lastViewport
    workspace = workspace.updatingTab(tabID) { tab in
        let (canvas, id) = tab.canvas.adding(spec, near: tab.focusedPane, viewport: viewport)
        tab.canvas = canvas
        tab.focusedPane = id
        if tab.maximizedPane != nil { tab.maximizedPane = nil }      // a new pane exits maximize
        // In-view guarantee: if the new item is off-viewport, pan to center it.
        let vis = CGRect(origin: canvas.camera.origin, size: viewport)
        if let f = canvas.frame(of: id), !f.intersects(vis) {
            tab.canvas = tab.canvas.centered(on: id, viewport: viewport)
        }
    }
    reconcile()
}

public func movePane(_ id: PaneID, by delta: CGSize) {              // chrome drag-to-move commit
    guard let tabID = tabID(owning: id) else { return }
    workspace = workspace.updatingTab(tabID) { tab in
        tab.canvas = tab.canvas.moving(id, by: delta).raising(id)
        tab.focusedPane = id
    }
    reconcile()                                                     // leaf set unchanged → registry no-op
}

public func resizePane(_ id: PaneID, to frame: CGRect) {           // corner/edge drag commit
    guard let tabID = tabID(owning: id) else { return }
    workspace = workspace.updatingTab(tabID) { $0.canvas = $0.canvas.resizing(id, to: frame) }
    reconcile()                                                     // VIEW frame change drives layout()→reflow
}

public func raisePane(_ id: PaneID) {                              // bring-to-front on focus/drag-start
    guard let tabID = tabID(owning: id) else { return }
    workspace = workspace.updatingTab(tabID) { $0.canvas = $0.canvas.raising(id); $0.focusedPane = id }
    reconcile()
}

public func commitCamera(_ camera: CanvasCamera) {                // committed pan (debounced-persisted)
    guard let tabID = workspace.activeTabID else { return }
    workspace = workspace.updatingTab(tabID) { $0.canvas = $0.canvas.camera(camera) }
    reconcile()
}

public func centerOnPane(_ id: PaneID) {                          // "Center on Pane" + off-screen reveal
    guard let tabID = tabID(owning: id) else { return }
    workspace = workspace.updatingTab(tabID) { $0.canvas = $0.canvas.centered(on: id, viewport: lastViewport) }
    reconcile()
}

public func centerOnAll() {                                       // "Center on All" (NOT "Fit")
    guard let tabID = workspace.activeTabID else { return }
    workspace = workspace.updatingTab(tabID) { $0.canvas = $0.canvas.centeredOnAll(viewport: lastViewport) }
    reconcile()
}

public func tidyActiveTab() {                                     // "Tidy" — pack to grid
    guard let tabID = workspace.activeTabID else { return }
    workspace = workspace.updatingTab(tabID) { $0.canvas = $0.canvas.tidied(viewport: lastViewport) }
    reconcile()
}
```

Per-frame *live* pan is **view `@State`** and never touches the store (mirrors `SplitContainer`'s `@GestureState` discipline); only the committed `.onEnded` calls `commitCamera`. `commitCamera/center*/tidy` ride the existing `saveDebounce` via `reconcile → scheduleSave` (no new persistence path).

### 5.5 `closePane` reworked (exact contract kept)
```swift
public func closePane(_ id: PaneID) {
    guard let tabID = tabID(owning: id) else { return }
    let refocus = neighbourForRefocus(of: id, inTab: tabID)   // geometric, captured before close
    var closedTab = false
    workspace = workspace.updatingTab(tabID) { tab in
        guard let newCanvas = tab.canvas.removing(id) else { closedTab = true; return }
        tab.canvas = newCanvas
        if tab.focusedPane == id { tab.focusedPane = refocus ?? newCanvas.allIDs().first ?? tab.focusedPane }
        if tab.maximizedPane == id { tab.maximizedPane = nil }
    }
    if closedTab { workspace = workspace.closing(tabID) }
    reconcile()
}
```

### 5.6 Other store edits
- `focus` :340-346, `move` :351-369, `updateSpec` :428-434, `toggleZoom` :374-380 — bodies unchanged except `.root`→`.canvas` reads and `zoomedPane`→`maximizedPane` (`toggleZoom` keeps its name, flips `maximizedPane`).
- `apply(_:to:)` :988-1034 — `.splitHorizontal/.splitVertical` → `.newPane` (`store.addPane(kind:.terminal)`); add `.tidy → store.tidyActiveTab()`, `.centerFocusedPane → if let p = store.activeTab?.focusedPane { store.centerOnPane(p) }`. `.toggleZoom → store.toggleZoom()` unchanged. Rest unchanged.

---

## 6. Views + gestures

### 6.1 Mount switch (`WorkspaceRootView.swift:102-113`) — regular branch only
```swift
if compact {
    PaneCarouselView(store: store, onShowTabs: { columnVisibility = .all })   // unchanged projection (reads adapted)
} else {
    CanvasView(store: store, tab: store.activeTab!.id)                        // was: PaneTreeView(node: ..root, ..)
}
```
The size-class flip stays view-only (no reconcile). `PaneTreeView.swift` + `SplitContainer.swift` are deleted.

### 6.2 `CanvasView` — the pannable plane (new file)
Responsibilities: one rigid `.offset` camera; kind-aware culling; maximize branch; report `solvedLayout()` (geometric focus, replacing `PaneTreeView.layoutReporter`), viewport size, and viewport membership.

```swift
struct CanvasView: View {
    let store: WorkspaceStore
    let tab: TabID
    @GestureState private var livePan: CGSize = .zero          // rigid live pan preview; commit on end
    private static let coordSpace = "canvas"

    private var activeTab: Tab? { store.workspace.tabs.first { $0.id == tab } }
    private var canvas: Canvas { activeTab?.canvas ?? Canvas(items: []) }

    var body: some View {
        GeometryReader { geo in
            let camera = canvas.camera
            ZStack(alignment: .topLeading) {
                if let maxID = activeTab?.maximizedPane, canvas.contains(maxID) {
                    maximizedBody(maxID, viewport: geo.size)     // full-bleed one item, ignore camera/culling
                } else {
                    backgroundHitLayer                            // bottom: Color.clear + contentShape + iOS pan
                    canvasContent(camera: camera, viewport: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .coordinateSpace(.named(Self.coordSpace))
            #if os(macOS)
            .overlay { CanvasScrollCatcher { d in store.commitCamera(canvas.camera.translated(by: d)) } }
            #endif
            .overlay(alignment: .bottomTrailing) { recenterButton(viewport: geo.size) }
            .onAppear { report(geo.size, camera: camera) }
            .onChange(of: geo.size) { _, s in report(s, camera: canvas.camera) }
            .onChange(of: canvas) { _, _ in report(geo.size, camera: canvas.camera) }
        }
        .background(.background)
    }

    private func canvasContent(camera: CanvasCamera, viewport: CGSize) -> some View {
        let visible = CanvasGeometry.visibleItems(canvas.items, camera: camera, viewport: viewport,
                                                  focused: activeTab?.focusedPane)
        return ZStack(alignment: .topLeading) {
            ForEach(visible.sorted { $0.z < $1.z }) { item in
                CanvasItemView(item: item, store: store, tab: tab, coordSpace: Self.coordSpace)
                    .frame(width: item.frame.width, height: item.frame.height)
                    .position(x: item.frame.midX, y: item.frame.midY)   // canvas-space; CONSTANT during pan
                    .zIndex(Double(item.z))
                    .id(item.id)                                          // LOAD-BEARING (.id(PaneID))
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)   // explicit size for .position
        .offset(x: -camera.origin.x - livePan.width, y: -camera.origin.y - livePan.height)  // ONLY camera application (rigid)
    }

    private var backgroundHitLayer: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .updating($livePan) { v, s, _ in s = CGSize(width: -v.translation.width, height: -v.translation.height) }
                .onEnded { v in
                    store.commitCamera(canvas.camera.translated(by: CGSize(width: -v.translation.width,
                                                                           height: -v.translation.height)))
                })
    }

    private func report(_ size: CGSize, camera: CanvasCamera) {
        guard size.width > 0, size.height > 0 else { return }
        store.updateViewport(size)
        store.updateViewportMembership(CanvasGeometry.viewportMembers(canvas.items, camera: camera, viewport: size))
        if let maxID = activeTab?.maximizedPane, canvas.contains(maxID) {
            store.updateSolvedLayout(SolvedLayout(frames: [maxID: CGRect(origin: .zero, size: size)], dividers: []))
        } else {
            store.updateSolvedLayout(canvas.solvedLayout())   // canvas-space; FocusResolver consumes unchanged
        }
    }
}
```
(`CanvasCamera.translated(by:)` is a tiny pure helper = `camera.origin += delta`.) Use one `@GestureState livePan` for the rigid live preview; the macOS scroll path commits directly (wheel deltas are discrete).

The camera is applied as **one rigid `.offset`** on the content ZStack — `.offset` is a rendering translate that does NOT change child `bounds`, so each item's `GhosttyLayerBackedView` keeps `bounds == frame == 1:1` and `layout()` derives correct cols/rows; mouse points map 1:1. The content ZStack gets an explicit `.frame(viewport)` so `.position` lays out absolutely (HW-flag below).

### 6.3 `CanvasScrollCatcher` (macOS pan, new — `NSViewRepresentable`)
`DragGesture` cannot see trackpad scroll/wheel, and `ScrollView`/`.onScrollGeometryChange` impose content-size/clip semantics incompatible with absolute `.position` + culling. Use a dedicated catcher (same drop-to-AppKit idiom as `WindowWidthReader`):
```swift
#if os(macOS)
struct CanvasScrollCatcher: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    func makeNSView(context: Context) -> NSView { ScrollCatchView(onPan: onPan) }
    func updateNSView(_ v: NSView, context: Context) { (v as? ScrollCatchView)?.onPan = onPan }
    final class ScrollCatchView: NSView {
        var onPan: (CGSize) -> Void
        init(onPan: @escaping (CGSize) -> Void) { self.onPan = onPan; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ p: NSPoint) -> NSView? { nil }   // pass clicks THROUGH to panes
        override func scrollWheel(with e: NSEvent) {
            let dx, dy: CGFloat
            if e.hasPreciseScrollingDeltas { dx = e.scrollingDeltaX; dy = e.scrollingDeltaY }
            else { dx = e.scrollingDeltaX * 10; dy = e.scrollingDeltaY * 10 }
            onPan(CGSize(width: -dx, height: -dy))   // natural-scroll: content follows fingers
        }
    }
}
#endif
```
It returns `nil` from `hitTest` so it never steals a click (libghostty `mouseDown` still reaches the body), but `scrollWheel` is routed to it by location. Mounted as a hit-transparent `.overlay`.

### 6.4 `CanvasItemView` — one positioned pane (new file)
Reuses `PaneChromeView` + `PaneLeafView` **verbatim** (the body is `PaneTreeView.leafView` plus move/resize gestures). Gesture layering is by **region** (hit-test), priority only where regions overlap.

```swift
struct CanvasItemView: View {
    let item: CanvasItem
    let store: WorkspaceStore
    let tab: TabID
    let coordSpace: String
    @GestureState private var moveLive: CGSize = .zero
    @GestureState private var resizeLive: CGRect? = nil

    var body: some View {
        let shown = resizeLive ?? item.frame
        PaneChromeView(
            id: item.id, spec: item.spec, handle: store.handle(for: item.id),
            isFocused: store.isFocused(item.id),
            isZoomed: store.activeTab?.maximizedPane == item.id,
            store: store,
            moveHandleGesture: moveGesture                     // NEW additive param — attached to the header only
        ) {
            PaneLeafView(handle: store.handle(for: item.id), spec: item.spec,
                         isFocused: store.isFocused(item.id),
                         focusCoordinator: store.focusCoordinator, store: store)
        }
        .frame(width: shown.width, height: shown.height)       // resize previews live (intended reflow, coalesced)
        .offset(x: moveLive.width, y: moveLive.height)         // move previews RIGID (no bounds change → no reflow)
        .overlay { resizeHandles }                             // 8 corner/edge grips, contentShape(Rectangle())
        .onAppear { wireFocusOnClick(for: item.id) }           // verbatim from PaneTreeView.wireFocusOnClick
        #if os(iOS)
        .simultaneousGesture(TapGesture().onEnded { store.focus(item.id) })  // absorb touch → focus, block bg pan
        #endif
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($moveLive) { v, s, _ in s = v.translation }
            .onEnded { v in store.movePane(item.id, by: v.translation) }      // ONE commit (raise+focus inside)
    }
    private func resizeGesture(_ anchor: ResizeAnchor) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($resizeLive) { v, s, _ in
                s = CanvasGeometry.resizing(item.frame, anchor: anchor, by: v.translation, minSize: Canvas.minItemSize)
            }
            .onEnded { v in
                let f = CanvasGeometry.resizing(item.frame, anchor: anchor, by: v.translation, minSize: Canvas.minItemSize)
                store.resizePane(item.id, to: f)               // ONE commit → layout()→setPixelSize→TIOCSWINSZ once
            }
    }
}
```

`PaneChromeView` gains **one additive parameter** `moveHandleGesture: some Gesture` attached to the **header HStack only** (`PaneChromeView.swift:51-88`) — dragging the header moves the pane; dragging the body reaches the terminal. **Move = rigid `.offset` preview, commit on end** (no per-frame `setSize` storm — mirrors `SplitContainer`'s commit-on-end). The dragged item floats to top during the drag via `.zIndex(.greatestFiniteMagnitude)` when `moveLive != .zero` (the real z bump persists on commit via `movePane`'s `raising(id)`). Because the camera is pure translation, a `.named("canvas")` translation IS the canvas-space delta (no scale to divide). **Resize = live `.frame` preview** which deliberately reflows (native feel); the TIOCSWINSZ storm is absorbed downstream by `TerminalViewModel.sendResize` dedup + host `MuxChannelSession` resizeDebounce — so the single `.onEnded` commit only persists the final frame.

### 6.5 Gesture layering table
| Region | macOS | iOS | Modifier |
|---|---|---|---|
| Empty background | `scrollWheel` → `commitCamera` (CanvasScrollCatcher, `hitTest=nil`) | one-finger `DragGesture(min:8)` on bottom `Color.clear` → `commitCamera` | `.gesture` (lowest, bottom layer) |
| Terminal body | libghostty `mouseDown` (selection/reporting) + `onRequestFocus`→`store.focus` | passive `CAMetalLayer`; `.simultaneousGesture(Tap)`→`store.focus` | **NO** ancestor gesture on body |
| Chrome header | `DragGesture` → `movePane` | same | plain `.gesture` (region-isolated) |
| Resize handle | `DragGesture` → `resizePane` | same | plain `.gesture` (region-isolated) |

Why the body never loses its click: **never** `.highPriorityGesture` on/around the body (it would steal libghostty `mouseDown`); attach **no** gesture to the body; use plain `.gesture` on header/handles, which are region-isolated. The macOS `.onTapGesture { store.focus(id) }` that `PaneTreeView` put on the body (`PaneTreeView.swift:157`) is **removed** on the canvas (it competes with `mouseDown`); body focus comes from `onRequestFocus` (`wireFocusOnClick`, ported verbatim). iOS body focus is the `.simultaneousGesture(Tap)`; z-order keeps the background pan from firing under a pane (the `Color.clear` hit layer is the *bottom* of the ZStack). `focusCoordinator` is threaded to every item (multiple terminal hosts visible — needed unchanged). **Never call `surface.setFocus(false)` to mark a pane inactive** — dim is `.opacity` only (`PaneLeafView` pattern); every mounted terminal keeps `setFocus(true)` so all visible panes repaint (identical to tiling).

### 6.6 Compact carousel — kept, reads adapted
`PaneCarouselView` is reused (a tiny-pane plane is unusable on a phone). `CompactLayoutResolver` (`CompactLayoutResolver.swift:29-42`) reads the canvas in z-order:
```swift
public static func pages(for tab: Tab) -> [CompactPage] {
    tab.canvas.allIDs().compactMap { id in
        guard let spec = tab.canvas.spec(for: id) else { return nil }
        return CompactPage(id: id, kind: spec.kind, title: spec.title)
    }
}
public static func selectedIndex(for tab: Tab) -> Int {
    tab.canvas.allIDs().firstIndex(of: tab.focusedPane) ?? 0
}
```
`PaneCarouselView` edits: `tab.root.spec(for:)` → `tab.canvas.spec(for:)` (:99); `tab.zoomedPane` → `tab.maximizedPane` (:105); `tab.root.contains` → `tab.canvas.contains` (:245); the `addMenu`/`primaryAction` `store.split(...)` calls → `store.addPane(kind:)` (:195-212). Keeps `.id(PaneID)` (:126). The compact path leaves `paneIDsInViewport` empty → `isPaneVisible` falls back to `isPaneOnActiveTab` (no regression).

### 6.7 Other coupled views
- `PaneChromeView.controls` (:94-110): replace the two `splitMenu(...)` (:96-97, :115-146) with one `addMenu` (`+`, kind picker → `store.addPane(kind:)`). Keep zoom (label "Maximize"/"Restore") + close. Add the `moveHandleGesture` param + attach to the header HStack.
- `TabSidebarView`: `tab.root.leafCount`→`tab.canvas.itemCount` (:83); `tab.root.allLeafIDs()`→`tab.canvas.allIDs()` (:167,:179); `tab.root.spec(for:)`→`tab.canvas.spec(for:)` (:178-179).
- `CommandPaletteView` pane-jump (:326-328): `tab.root.leafCount`→`tab.canvas.itemCount`; `tab.root.allLeafIDs()`→`tab.canvas.allIDs()`; `tab.root.spec(for:)`→`tab.canvas.spec(for:)`. Add palette rows: New Pane / Tidy / Center on Pane / Center on All / Maximize.

### 6.8 HW-validation needs (cannot be headless; flag for the cua/Maestro pass — do not block merge)
1. **macOS chrome-header `DragGesture` coexisting with libghostty body `mouseDown`** — text selection inside the terminal body still works with the canvas present (the single riskiest interaction). Fallback if it fails: shrink the move grip to a small dedicated drag glyph in the header.
2. macOS `scrollWheel` natural-scroll direction/sign + momentum on a real trackpad vs Finder.
3. Live resize drag driving `GhosttyLayerBackedView.layout()` without retearing (the "vỡ"/"broken" symptom) — same path as the patched window-resize, new trigger.
4. Cull → re-mount of a **video** surface when panned off-viewport and back (activate/deactivate + cap re-admission); confirm terminals (kept mounted) repaint on pan-back with no flash.
5. `.position` inside the explicitly-sized content `ZStack` lays out absolutely + `.clipped()` window behaves on both platforms.
6. Off-viewport video pane frees its cap slot (the `isPaneVisible` guard) — pan a live `.remoteGUI` pane off-screen, confirm a gated sibling promotes.

---

## 7. Commands / keyboard

Conflict rule preserved: every workspace chord stays ⌘/⌥-prefixed (bare keys + Ctrl-letters fall through to the terminal). `WorkspaceCommand` (`CommandInterpreter.swift:10-24`):

```swift
public enum WorkspaceCommand: Sendable, Equatable {
    case newPane                   // ⌘D   — replaces splitHorizontal
    case tidy                      // ⇧⌘D  — replaces splitVertical (pack to grid)
    case centerFocusedPane         // ⌥⌘C  — NEW (center camera on focused pane; the pan-only "Recenter")
    case closePane                 // ⌘W
    case closeTab                  // ⇧⌘W
    case newTab                    // ⌘T
    case nextTab                   // ⌃⇥
    case prevTab                   // ⌃⇧⇥
    case selectTab(Int)            // ⌘1…⌘9
    case focus(FocusDirection)     // ⌥⌘←/→/↑/↓ — UNCHANGED (FocusResolver reuse)
    case cycleFocus(forward: Bool) // ⌘] / ⌘[  — UNCHANGED
    case toggleZoom                // ⇧⌘↩  — kept (flips maximizedPane; label "Maximize Pane")
    case renameTab                 // ⌘R
    case reconnectPane             // ⇧⌘R
}
```
Removed: `.splitHorizontal`, `.splitVertical` (no axis). Reusing the two split chords keeps muscle-memory productive: `⌘D` = New Pane, `⇧⌘D` = Tidy. `⌥⌘C` = Center (⌥⌘ avoids ⌘C copy).

`CommandInterpreter.defaultBindings` (:110-152) edits:
```swift
map[KeyChord(character: "d", [.command])] = .newPane              // was .splitHorizontal
map[KeyChord(character: "d", [.command, .shift])] = .tidy         // was .splitVertical
map[KeyChord(character: "c", [.option, .command])] = .centerFocusedPane  // NEW
// w/t/tab/1-9/arrows/]/[/return/r/⇧r — UNCHANGED
```

`apply(_:to:)` (`WorkspaceStore.swift:990-1019`):
```swift
case .newPane:            store.addPane(kind: .terminal)
case .tidy:               store.tidyActiveTab()
case .centerFocusedPane:  if let p = store.activeTab?.focusedPane { store.centerOnPane(p) }
case .toggleZoom:         store.toggleZoom()
// closePane/closeTab/newTab/nextTab/prevTab/selectTab/focus/cycleFocus/renameTab/reconnectPane — UNCHANGED
```

`WorkspaceCommands.swift` Pane menu (the menu derives shortcuts from the bindings table): "Split Right"/"Split Down" → "New Pane"/"Tidy Layout"; add "Center on Pane" (`.centerFocusedPane`) + "Center on All" (→ `store.centerOnAll()`, a menu-only action); "Zoom Pane" → "Maximize Pane".

---

## 8. File-by-file plan

**Create**
- `Sources/AislopdeskClientUI/Workspace/Domain/Canvas.swift` — `Canvas`, `CanvasItem`, `CanvasCamera` + metrics.
- `Sources/AislopdeskClientUI/Workspace/Domain/Canvas+Ops.swift` — queries + mutations + camera/arrange + `solvedLayout()`.
- `Sources/AislopdeskClientUI/Workspace/Domain/Canvas+Codable.swift` — defensive `init(from:)`/`encode(to:)` + `sanitize`.
- `Sources/AislopdeskClientUI/Workspace/Domain/CanvasGeometry.swift` — `ResizeAnchor`, `resizing`, `placement`, `screenRect`, `visibleItems`, `viewportMembers`.
- `Sources/AislopdeskClientUI/Workspace/Domain/SolvedLayout.swift` — `SolvedLayout` + `DividerHandle` (extracted from LayoutSolver so they survive the quarantine).
- `Sources/AislopdeskClientUI/Workspace/Legacy/WorkspaceV1Migration.swift` — pre-decode peek + legacy mirrors + reshape.
- `Sources/AislopdeskClientUI/Workspace/Views/CanvasView.swift` — pannable plane + `CanvasScrollCatcher` + recenter button + maximize branch.
- `Sources/AislopdeskClientUI/Workspace/Views/CanvasItemView.swift` — positioned pane + move/resize gestures + handles.
- Tests: `CanvasOpsTests.swift`, `CanvasGeometryTests.swift`, `CanvasCullingTests.swift`, `WorkspaceV1MigrationTests.swift`, `CanvasFocusTests.swift`.

**Modify**
- `Domain/Tab.swift` — `root`→`canvas`, `zoomedPane`→`maximizedPane`, `Tab.make`.
- `Domain/Workspace.swift` — `currentSchemaVersion=2`; `normalizingTabFocus` `.root`→`.canvas`.
- `Domain/CompactLayoutResolver.swift` — `pages`/`selectedIndex` → canvas reads (z-order).
- `Store/WorkspaceStore.swift` — §5 reads; delete `split`/`setFractions`; add `addPane`/`movePane`/`resizePane`/`raisePane`/`commitCamera`/`centerOnPane`/`centerOnAll`/`tidyActiveTab`/`updateViewport`/`updateViewportMembership`/`isPaneVisible`/`lastViewport`/`paneIDsInViewport`; rework `closePane`; `apply(_:to:)` cases.
- `Store/WorkspacePersistence.swift` — pre-decode peek branch in `load()` + `dedupingLeafIDs`→`dedupingItemIDs`.
- `Store/CommandInterpreter.swift` — `WorkspaceCommand` cases + `defaultBindings`.
- `Views/WorkspaceRootView.swift` — regular branch → `CanvasView` (:111).
- `Views/PaneChromeView.swift` — additive `moveHandleGesture` on header; `splitMenu`×2 → one `addMenu`; zoom label "Maximize".
- `Views/PaneCarouselView.swift` — canvas reads (:99,:105,:245) + `store.split`→`store.addPane` (:195-212).
- `Views/PaneLeafView.swift` — teardown guard `isPaneOnActiveTab`→`isPaneVisible` (:642).
- `Views/CommandPaletteView.swift` — pane-jump canvas reads (:326-328) + arrange rows.
- `Views/WorkspaceCommands.swift` — Pane menu labels/items.
- `Views/TabSidebarView.swift` — canvas reads (:83,:167,:178-179).

**Move to `Legacy/` (internal, decode/migration-only — NOT deleted)**
- `Domain/PaneNode.swift` → `Legacy/PaneNode.swift`; `Domain/PaneNode+Codable.swift` → `Legacy/PaneNode+Codable.swift`; `Domain/LayoutSolver.swift` → `Legacy/LayoutSolver.swift` (top-of-file "LEGACY" doc; `SplitAxis` rides with it).

**Delete**
- `Views/PaneTreeView.swift`, `Views/SplitContainer.swift` (incl. `DividerHandleView`).

---

## 9. Test plan

### 9.1 Pure (plain XCTest, no client, no async — the ~85% seam)
- `CanvasOpsTests`: `allIDs` z-order determinism (ties by id); `adding` (z=maxZ+1, focus-target exists, frame from `placement`); `moving`/`resizing` (min-floor clamp, opposite-edge pin, finite clamp for NaN/inf delta); `raising` (idempotent at top, brings to front); `removing` (→ nil on last == tab-empties contract, survivor z preserved); `hitTest` (z-desc, overlapping stack → frontmost); `dedupingItemIDs` (re-mints dups, first kept); `contains`/`frame`/`spec`/`itemCount`/`maxZ`; `panned` (no /scale); `centered` (item center → viewport center); `centeredOnAll` (bbox; empty → identity; bbox > viewport stays centered, NOT shrunk); `tidied` (grid, no overlap, z preserved, camera recentered); `needsRecenter`.
- `CanvasGeometryTests`: `screenRect` 1:1 (width/height verbatim, translate only); `resizing` table-driven over all 8 `ResizeAnchor` (anchored edges move, opposite pinned, floor clamps); `placement` (≤25% overlap, cascaded from focus, terminates via the step cap, viewport-center when `near: nil`).
- `CanvasCullingTests`: `visibleItems` (terminals always present; video culled outside viewport+margin; focused video never culled; pure determinism); `viewportMembers` (intersection-only, no margin, no kind filter).
- `WorkspaceV1MigrationTests`: a hand-authored **v1 JSON fixture** (3-leaf nested split, endpoints + a `zoomedPane` + non-first `activeTabID`/`focusedPane`) → `load()` → schemaVersion==2; every PaneID/TabID survives; item count == leaf count; every spec preserved; `maximizedPane`==v1 `zoomedPane`; frames finite, ≥ minItemSize, preserve tiled adjacency (left.minX < right.minX for a horizontal split); round-trip (save migrated → reload → identical). Plus: v0 fixture (dangling activeTabID repaired); future-v3 → `resetToDefault` + `.corrupt` sidecar; hard-corrupt → default + sidecar; duplicate-id v1 → re-minted (no collapsed sessions); unversioned-but-v1-shaped → legacy branch.
- `CanvasFocusTests`: build `Canvas` with known frames; `canvas.solvedLayout()` feeds `FocusResolver.neighbor` to the correct left/right/up/down + cycle; overlap-tie deterministic; off-viewport target navigable (canvas-space, camera-independent). **`FocusResolverTests` kept verbatim** (it already builds `SolvedLayout` from explicit frames).

### 9.2 FakePaneSession store tests (adapt — the seam stays)
- `WorkspaceStoreReconcileTests`: build tabs with `Canvas`; assert `Set(registry.keys)==Set(activeTab.canvas.allIDs())` after `addPane`/`closePane`/`movePane`/`resizePane`/`raisePane`/`commitCamera`/`center*`/`tidy`; `move/resize/raise/pan/center/tidy/commitCamera` are registry no-ops (no materialize/teardown); `addPane` materializes exactly one; `closePane` of last item closes the tab; `.adopt(leafID)` first event after add.
- `LiveVideoCapTests` (extend, not rewrite): the `isPaneVisible` fix — a video pane reported OUT of `updateViewportMembership` deactivates (frees a slot + bumps `videoPromotionGeneration`); a pane still in the set self-cancels the spurious teardown; empty set → falls back to `isPaneOnActiveTab` (no regression).
- `WorkspacePersistenceTests` (extend): v1→v2 load fixture; v2 byte-stable round-trip; corrupt/non-finite frame → sanitized/default + `.corrupt` sidecar; duplicate-id re-mint.
- `CompactLayoutResolverTests` (adapt): pages == `canvas.allIDs()` z-order; `selectedIndex` from `focusedPane`.
- `CommandRoutingTests`/`CommandInterpreterTests` (adapt): `⌘D→.newPane`, `⇧⌘D→.tidy`, `⌥⌘C→.centerFocusedPane`, focus/cycle/zoom/tab chords unchanged; no bare-key binding; `apply(.newPane)` materializes a pane, `apply(.centerFocusedPane)` moves only the camera.
- `CommandPaletteEntriesTests`, `ScenePhaseFanOutTests`, `WorkspaceStoreReconnectGuardTests`, `WorkspaceTests`: adapt the few `.root`/`split` references.

### 9.3 Delete
`PaneNodeTests`, `LayoutSolverTests`, `FractionTests` (split-specific). Keep a thin `LayoutSolverSeedTests` asserting the seeding the migration relies on (so the migration's frame source stays covered), and a thin `PaneNodeDecodeTests` asserting the legacy decoder still parses a v1 fixture.

---

## 10. Ordered implementation steps (build checklist — each independently buildable+testable)

1. **Domain types + Codable.** Create `Canvas.swift`, `Canvas+Codable.swift`, `SolvedLayout.swift` (extract `SolvedLayout`/`DividerHandle`). No callers yet. Build the Domain target. *Depends on: nothing.*
2. **Pure ops + geometry.** Create `Canvas+Ops.swift`, `CanvasGeometry.swift`. Write `CanvasOpsTests` + `CanvasGeometryTests` + `CanvasCullingTests`; run green. *Depends on: 1.*
3. **Quarantine legacy.** Move `PaneNode.swift`/`PaneNode+Codable.swift`/`LayoutSolver.swift` → `Legacy/`, drop `public`. Build (everything still references them via the old paths — this step will break the build; do it together with step 4's migration + step 6's store reads, OR keep them `public` in `Legacy/` until step 7 then tighten). Practical order: keep them `public` in `Legacy/` now; tighten to `internal` after step 7. *Depends on: 1.*
4. **Migration.** Create `Legacy/WorkspaceV1Migration.swift`; wire the pre-decode peek into `WorkspacePersistence.load()` (+ `dedupingItemIDs`). Write `WorkspaceV1MigrationTests`. *Depends on: 1, 3, and `Tab.canvas` (step 5).* — co-land with 5.
5. **Tab + Workspace.** `Tab.root`→`canvas`, `zoomedPane`→`maximizedPane`, `Tab.make`; `Workspace.currentSchemaVersion=2`, `normalizingTabFocus`. This breaks the store + views (expected). *Depends on: 1.*
6. **Store.** Apply all §5 edits (reads, delete split/setFractions, new mutations, viewport/membership/`isPaneVisible`, `closePane`). `apply(_:to:)` left referencing old command cases until step 8 — temporarily stub `.newPane`/`.tidy`/`.centerFocusedPane` once 8 lands; OR co-land 6+8. Build the store. *Depends on: 2, 5.*
7. **CompactLayoutResolver + coupled-view reads.** `CompactLayoutResolver`, `TabSidebarView`, `CommandPaletteView` canvas reads. *Depends on: 5, 6.*
8. **Commands.** `WorkspaceCommand` cases + `defaultBindings` + `apply(_:to:)` + `WorkspaceCommands` menu. Write `CommandRoutingTests`. *Depends on: 6.*
9. **PaneChromeView.** Additive `moveHandleGesture` on header; `splitMenu`×2 → `addMenu`; zoom→"Maximize". *Depends on: 6.*
10. **CanvasItemView.** New file — chrome+leaf, move/resize gestures, handles, focus wiring. *Depends on: 2, 6, 9.*
11. **CanvasView + CanvasScrollCatcher.** New file — pannable plane, culling, maximize branch, reporters, recenter button, macOS scroll catcher, iOS bg pan. *Depends on: 2, 6, 10.*
12. **Mount switch.** `WorkspaceRootView` regular branch → `CanvasView`; `PaneCarouselView` reads + `addPane`. Delete `PaneTreeView.swift`/`SplitContainer.swift`. *Depends on: 7, 11.*
13. **PaneLeafView teardown guard** → `isPaneVisible`. Extend `LiveVideoCapTests`. *Depends on: 6.*
14. **Adapt remaining store/persistence/compact tests** (`WorkspaceStoreReconcileTests`, `WorkspacePersistenceTests`, `CompactLayoutResolverTests`, `WorkspaceTests`, etc.); delete `PaneNodeTests`/`LayoutSolverTests`/`FractionTests`; keep the thin seed/decode tests. *Depends on: all above.*
15. **Tighten legacy to `internal`**; full sweep green; iOS + macOS build. *Depends on: all above.*
16. **HW-validation pass** (§6.8 items 1–6) via cua/Maestro — gate before any merge/commit.

---

## 11. Top risks + mitigations

1. **v1→v2 migration data-loss / launch-brick** (the project's recurring failure mode — R13 nuke-to-default). A wrong peek branch would silently discard every existing user's workspace. *Mitigation:* the peek tries v2 then legacy and only `resetToDefault()`s when both fail; `resetToDefault` writes the `.corrupt` sidecar (original bytes recoverable, never destroyed); `migrateIfLegacy`/`reshape` are pure + total (no force-unwrap, no throw; degenerate leaf → default item; zero-item tab → single terminal); `Canvas.sanitize` clamps every frame finite + ≥ minItemSize at two layers (reshape + decode); id-preservation + `dedupingItemIDs` asserted by `WorkspaceV1MigrationTests`; the existing `savingEnabled` gate defers the first save past the restore reconcile, so a migration bug surfaces as a recoverable in-memory default with the sidecar intact, never an overwrite of the good v1 file.
2. **macOS chrome-header `DragGesture` stealing libghostty body `mouseDown`** (breaks text selection/mouse-reporting; the surface is documented-delicate). *Mitigation:* region isolation, never priority — the move gesture is attached only to the header HStack, a plain `.gesture` (never `.highPriorityGesture`), and the body has zero ancestor gestures; `minimumDistance: 2` so a header click still focuses; the `onRequestFocus` focus path is kept verbatim. HW item #1 is the mandatory acceptance test; fallback is a small dedicated drag glyph.
3. **Culling unmounting a terminal surface → stale-frame replay for alt-screen TUIs.** *Mitigation:* terminals are **never culled** (kept mounted, translated off-viewport, `setFocus(true)`); only `.remoteGUI` panes cull; the focused pane is never culled. Encoded in the pure `visibleItems`, unit-tested.
4. **Off-viewport video pane never freeing its cap slot** (`isPaneOnActiveTab` == "on active tab" ≠ "on screen" on a canvas). *Mitigation:* the `isPaneVisible` signal (active-tab AND in-viewport) gates the teardown re-check, with an empty-set fallback that keeps every non-canvas path byte-identical; tested in `LiveVideoCapTests` + HW item #6.
5. **`.position` not laying out without an explicitly-sized container.** *Mitigation:* the content ZStack gets an explicit `.frame(viewport)` + `.clipped()`; HW item #5; fallback is per-item `.position(screenRect(...).center)`.
6. **Lost-in-empty-space (no zoom-to-fit).** *Mitigation:* `needsRecenter` → a visible "Recenter" button; the `addPane` in-view guarantee; `centerOnPane`/`centerOnAll`/`tidy` commands; focusing an off-screen pane wires through `centerOnPane`.

---

### Source anchors (verified)
`Sources/AislopdeskClientUI/Workspace/Domain/{Tab.swift,Workspace.swift,LayoutSolver.swift,CompactLayoutResolver.swift,PaneNode.swift,PaneNode+Codable.swift}`, `Sources/AislopdeskClientUI/Workspace/Store/{WorkspaceStore.swift,WorkspacePersistence.swift,WorkspaceSchemaMigration.swift,CommandInterpreter.swift}`, `Sources/AislopdeskClientUI/Workspace/Views/{PaneTreeView.swift,SplitContainer.swift,PaneChromeView.swift,PaneCarouselView.swift,PaneLeafView.swift,WorkspaceRootView.swift,CommandPaletteView.swift,TabSidebarView.swift,WorkspaceCommands.swift}`, and the libghostty spine `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` (`layout()` bounds×scale + `layer.bounds==view.bounds`; `mouseDown` y-flip) + `Sources/AislopdeskClientUI/Terminal/TerminalViewModel.swift` (`sendResize` dedup).

---

## Addendum — migration dropped (2026-06-06)

Per the product owner, the app has **no released persisted format and no users**, so the v1(split-tiling)→v2(canvas) backward-compat migration in §4.4 was **not built / removed**: there is no `WorkspaceV1Migration`, no quarantined legacy `PaneNode` / `LayoutSolver`, and `WorkspacePersistence.load()` simply decodes the canvas shape and falls back to the default (writing the `.corrupt` sidecar) on any failure — an older incompatible on-disk shape just fails to decode and resets. The now-dead `DividerHandle` / `SplitAxis` / `SolvedLayout.dividers` were also removed (the canvas has no dividers); `SolvedLayout` is just `{ frames: [PaneID: CGRect] }`, consumed by `FocusResolver` unchanged. Everything else in this spec shipped as written.
