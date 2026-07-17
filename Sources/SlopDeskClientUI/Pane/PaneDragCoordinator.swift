// PaneDragCoordinator — the cross-container half of the pane move gesture.
//
// The in-canvas drag (`SplitContainer` + `PaneMoveAffordance`) is plain SwiftUI confined to one tab's
// compositor. But the sidebar, the main canvas, and every satellite window live in SEPARATE hosting
// views (`NSSplitViewController` columns / plain `NSWindowController`s), so no SwiftUI coordinate space
// spans them. This coordinator is the shared meeting point: drop targets register lazy SCREEN-rect
// providers (resolved on demand at drag time — nothing publishes per layout pass), the live drag pushes
// its cursor + resolved destination here, and the sidebar/satellite surfaces read the PUBLISHED `drag`
// to draw their highlights. The cursor point itself is `@ObservationIgnored` — observers re-render on
// destination TRANSITIONS, never per pointer frame (the remote-app rule, extended across windows).
//
// Destination vocabulary (the superset of the in-canvas `PaneDropZone`):
//   • `.canvas(zone)`   — the existing swap/re-split/dock inside the main canvas;
//   • `.sidebarRow(p)`  — dropped on a sidebar row → the pane moves BESIDE that row's pane (its tab
//                          revealed) — `moveLeafAcrossTabsTree` / `reattachPaneTree(beside:)`;
//   • `.newTab`         — dropped on the sidebar's New-Tab slot → `breakPaneToTab` / reattach-to-new-tab;
//   • `.tearOff`        — released OUTSIDE the main window → detach into a satellite at the cursor;
//   • `.none`           — dead chrome / the source's own row → release cancels.
// Every commit keeps the `PaneID`, so reconcile never tears a live surface down — the move is pure
// geometry for the terminal / video session.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Vocabulary

/// Where a live pane drag STARTED: a tiled tree leaf (the in-canvas grab handle) or a detached
/// satellite window's grab strip. Decides the commit family (move vs reattach) and whether `.tearOff`
/// resolves (a satellite already is its own window).
enum PaneDragOrigin: Equatable {
    case tree
    case detached
}

/// The action releasing the drag at the current cursor would commit — the cross-container superset of
/// the in-canvas ``PaneDropZone``.
enum PaneDragDestination: Equatable {
    case canvas(PaneDropZone)
    case sidebarRow(PaneID)
    case newTab
    case tearOff
    case none
}

/// The keys drop-target frame providers register under. Sidebar rows key per-pane (a row is a pane,
/// not a tab — dropping on it lands BESIDE that pane).
enum PaneDropTargetKey: Hashable {
    case canvas
    case sidebarList
    case sidebarRow(PaneID)
    case newTabZone
}

// MARK: - Pure resolution (headlessly pinned)

/// The screen-rect snapshot a resolution runs against — gathered by the coordinator, but kept a plain
/// value so ``PaneDragResolver`` is pure and unit-pinned without views or windows.
struct PaneDragExternalTargets {
    /// The main workspace window's frame — the `.tearOff` boundary.
    var mainWindow: CGRect?
    /// The sidebar row list's visible viewport — a row hit counts only inside it (LazyVStack keeps
    /// scrolled-away rows mounted, so a raw row rect can sit outside the clip).
    var sidebarList: CGRect?
    /// Every registered sidebar row (screen rect), unordered.
    var rows: [(pane: PaneID, rect: CGRect)]
    /// The sidebar's New-Tab drop slot (mounted only while a drag is live).
    var newTabZone: CGRect?
}

/// Pure destination resolution — all inputs are screen-space rects, no view/window reach.
enum PaneDragResolver {
    /// Resolves a cursor OUTSIDE the main canvas. Precedence: sidebar row (clipped to the list
    /// viewport) → the New-Tab slot → dead main-window chrome (`.none`) → outside every window
    /// (`.tearOff`, tree drags only — a satellite already is a window, so its outside drop cancels).
    /// The source's own row resolves `.none` (dropping a pane on itself is a no-op — the preview must
    /// say so honestly). `sourceIsSoleLeafOfItsTab` gates `.newTab` for a tree drag: breaking a
    /// sole-leaf tab into "its own tab" is the identity op, so the slot reads as a cancel for it.
    static func externalDestination(
        at point: CGPoint,
        targets: PaneDragExternalTargets,
        origin: PaneDragOrigin,
        source: PaneID,
        sourceIsSoleLeafOfItsTab: Bool,
    ) -> PaneDragDestination {
        if let list = targets.sidebarList, list.contains(point) {
            for row in targets.rows where row.rect.intersection(list).contains(point) {
                return row.pane == source ? .none : .sidebarRow(row.pane)
            }
            // Inside the list but over a header / empty space — fall through to the slot / chrome checks.
        }
        if let zone = targets.newTabZone, zone.contains(point) {
            if origin == .tree, sourceIsSoleLeafOfItsTab { return .none }
            return .newTab
        }
        if let window = targets.mainWindow, window.contains(point) { return .none }
        // Outside the main window entirely. Without a known window frame the geometry is unreliable —
        // never tear off on a guess.
        guard targets.mainWindow != nil, origin == .tree else { return .none }
        return .tearOff
    }

    /// The INSERT-drag zone for a detached pane over the main canvas (canvas-local, top-left
    /// coordinates): the pane is not in the tab, so there is no swap and no source to exclude — the
    /// container gutter docks full-span, and anywhere over a leaf re-splits toward the NEAREST edge
    /// (band 0.5 ⇒ every interior point maps to its dominant edge; no dead centre). Deterministic
    /// under (impossible-in-practice) overlapping rects via a positional sort.
    static func insertZone(
        at point: CGPoint,
        frames: [PaneID: CGRect],
        container: CGRect,
    ) -> PaneDropZone {
        guard container.width > 0, container.height > 0, container.contains(point) else { return .none }
        if let edge = PaneDropGeometry.containerEdge(at: point, container: container, sourceRect: nil) {
            return .dock(edge: edge)
        }
        let ordered = frames.sorted {
            ($0.value.minY, $0.value.minX, $0.key.raw.uuidString)
                < ($1.value.minY, $1.value.minX, $1.key.raw.uuidString)
        }
        for (pane, rect) in ordered where rect.contains(point) && rect.width > 0 && rect.height > 0 {
            let u = (point.x - rect.minX) / rect.width
            let v = (point.y - rect.minY) / rect.height
            return .resplit(target: pane, edge: PaneDropGeometry.dominantEdge(u: u, v: v, band: 0.5))
        }
        return .none
    }

    /// Canvas-local (top-left origin) → screen (AppKit bottom-left) given the canvas's screen rect.
    static func screenPoint(fromCanvasLocal p: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX + p.x, y: canvas.maxY - p.y)
    }

    /// Screen (AppKit bottom-left) → canvas-local (top-left origin).
    static func canvasLocal(fromScreen p: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: p.x - canvas.minX, y: canvas.maxY - p.y)
    }
}

// MARK: - Coordinator

/// The shared drag rendezvous — created once at app `init` and threaded (like `preferences`) into the
/// sidebar / content columns and every satellite window, none of which share a hosting view.
@MainActor
@Observable
final class PaneDragCoordinator {
    /// The published shape of a live drag. Mutated only when a field CHANGES (destination
    /// transitions), never per cursor frame — observers (row highlights, canvas previews, the New-Tab
    /// slot) re-render on transitions only.
    struct Drag: Equatable {
        var source: PaneID
        var origin: PaneDragOrigin
        var destination: PaneDragDestination
    }

    /// The live drag, `nil` at rest.
    private(set) var drag: Drag?

    /// The live cursor (screen coords, AppKit bottom-left origin) — deliberately un-observed: it moves
    /// every frame and only the AppKit chip panel consumes it directly.
    @ObservationIgnored private(set) var screenPoint: CGPoint = .zero

    /// Lazy screen-rect providers, keyed by target. Resolved on demand at drag time — registration
    /// itself publishes nothing.
    @ObservationIgnored private var providers: [PaneDropTargetKey: () -> CGRect?] = [:]

    /// The main workspace window's frame — the `.tearOff` boundary. Registered by the canvas reader
    /// (the one drop target guaranteed to live in the main window).
    @ObservationIgnored var mainWindowFrame: () -> CGRect? = { nil }

    /// The ACTIVE tab's solved leaf rects + container bounds (canvas-local, top-left) — pushed by
    /// `SplitContainer.reportSolvedLayout` so a satellite-origin drag resolves canvas zones without a
    /// live view closure.
    @ObservationIgnored var canvasFrames: [PaneID: CGRect] = [:]
    @ObservationIgnored var canvasBounds: CGRect = .zero

    /// Screen points recorded at a `.tearOff` commit, consumed by the satellite-window coordinator to
    /// place the new window under the drop instead of the centre-cascade.
    @ObservationIgnored private var pendingPlacements: [PaneID: CGPoint] = [:]

    /// The live store — chip labels + the sole-leaf `.newTab` gate read it. Weak: the coordinator is
    /// app-lifetime glue, never an owner.
    @ObservationIgnored weak var store: WorkspaceStore?

    #if os(macOS)
    /// The cursor-following chip for the stretches where no canvas overlay can draw (the drag has left
    /// the content column's hosting view, which clips its SwiftUI overlay).
    @ObservationIgnored private let chipPanel = PaneDragChipPanel()
    #endif

    // MARK: Target registry

    func register(_ key: PaneDropTargetKey, provider: @escaping () -> CGRect?) {
        providers[key] = provider
    }

    func unregister(_ key: PaneDropTargetKey) {
        providers[key] = nil
    }

    func targetFrame(_ key: PaneDropTargetKey) -> CGRect? {
        providers[key]?()
    }

    /// Snapshot every registered external target for one pure resolution pass.
    func externalTargets() -> PaneDragExternalTargets {
        var rows: [(pane: PaneID, rect: CGRect)] = []
        for (key, provider) in providers {
            if case let .sidebarRow(id) = key, let rect = provider() {
                rows.append((id, rect))
            }
        }
        return PaneDragExternalTargets(
            mainWindow: mainWindowFrame(),
            sidebarList: targetFrame(.sidebarList),
            rows: rows,
            newTabZone: targetFrame(.newTabZone),
        )
    }

    // MARK: Drag lifecycle

    /// One drag frame: record the cursor, publish the (source, origin, destination) triple only when it
    /// changed, and move the chip panel.
    func update(source: PaneID, origin: PaneDragOrigin, screenPoint point: CGPoint, destination: PaneDragDestination) {
        screenPoint = point
        let next = Drag(source: source, origin: origin, destination: destination)
        if drag != next { drag = next }
        #if os(macOS)
        chipPanel.update(
            at: point,
            drag: next,
            label: chipLabel(for: next),
            symbol: Self.chipSymbol(for: next.destination),
        )
        #endif
    }

    /// Ends the drag and returns the final destination for the commit — one call from `.onEnded`.
    func takeDestination() -> PaneDragDestination {
        let destination = drag?.destination ?? .none
        end()
        return destination
    }

    /// Clears the drag (cancel path — a commit goes through ``takeDestination()``).
    func end() {
        if drag != nil { drag = nil }
        #if os(macOS)
        chipPanel.hide()
        #endif
    }

    /// One drag frame for a DETACHED (satellite grab strip) drag: the cursor is the global mouse
    /// location; canvas zones resolve from the pushed solved layout (insert semantics — no swap), the
    /// rest from the registered external targets.
    func updateDetachedDrag(source: PaneID) {
        #if os(macOS)
        let point = NSEvent.mouseLocation
        update(
            source: source, origin: .detached, screenPoint: point,
            destination: resolveDetachedDestination(at: point, source: source),
        )
        #endif
    }

    /// The destination a DETACHED drag resolves at `point` (screen coords). Canvas first (insert
    /// zones), then the shared external precedence.
    func resolveDetachedDestination(at point: CGPoint, source: PaneID) -> PaneDragDestination {
        if let canvas = targetFrame(.canvas), canvas.contains(point) {
            let local = PaneDragResolver.canvasLocal(fromScreen: point, canvas: canvas)
            let zone = PaneDragResolver.insertZone(at: local, frames: canvasFrames, container: canvasBounds)
            return zone == .none ? .none : .canvas(zone)
        }
        return PaneDragResolver.externalDestination(
            at: point, targets: externalTargets(), origin: .detached, source: source,
            sourceIsSoleLeafOfItsTab: false,
        )
    }

    /// The destination a TREE drag (in-canvas grab handle) resolves once its cursor leaves the canvas
    /// bounds — the canvas zones stay `SplitContainer`'s own live resolution.
    func resolveTreeExternalDestination(
        at point: CGPoint, source: PaneID, sourceIsSoleLeafOfItsTab: Bool,
    ) -> PaneDragDestination {
        PaneDragResolver.externalDestination(
            at: point, targets: externalTargets(), origin: .tree, source: source,
            sourceIsSoleLeafOfItsTab: sourceIsSoleLeafOfItsTab,
        )
    }

    // MARK: Tear-off placement hand-off

    func recordPlacement(_ pane: PaneID, at point: CGPoint) {
        pendingPlacements[pane] = point
    }

    func takePlacement(for pane: PaneID) -> CGPoint? {
        pendingPlacements.removeValue(forKey: pane)
    }

    // MARK: Chip content

    /// The chip's action label — short verb-first strings in the `PaneMoveOverlay.zoneLabel` register.
    private func chipLabel(for drag: Drag) -> String {
        switch drag.destination {
        case .canvas:
            return "" // the canvas overlay is the affordance there; the chip hides
        case let .sidebarRow(target):
            let spec = store?.tree.activeSession?.specs[target]
            let title = RailRowsBuilder.rowTitle(kind: spec?.kind ?? .terminal, spec: spec)
            let name = title.isEmpty ? "pane" : title
            return drag.origin == .detached ? "merge beside \(name)" : "move beside \(name)"
        case .newTab:
            return "new tab"
        case .tearOff:
            return "new window"
        case .none:
            return "cancel"
        }
    }

    static func chipSymbol(for destination: PaneDragDestination) -> SFSymbol {
        switch destination {
        case .canvas: .rectangle2Swap // unused (chip hidden over the canvas)
        case .sidebarRow: .rectangleStack
        case .newTab: .plusSquareOnSquare
        case .tearOff: .macwindow
        case .none: .xmark
        }
    }
}

#if os(macOS)

// MARK: - Screen-frame reader (drop-target registration)

/// Registers the decorated view's SCREEN frame with the drag coordinator under `key` — resolved lazily
/// through a weak `NSView` handle, so scrolling / layout never publishes anything. Mount it in a
/// `.background` (the view is hit-test transparent). The `.canvas` key doubles as the main-window
/// frame source (the tear-off boundary).
struct DropTargetFrameReader: NSViewRepresentable {
    let key: PaneDropTargetKey
    let coordinator: PaneDragCoordinator

    final class Coordinator {
        var registeredKey: PaneDropTargetKey?
        weak var drag: PaneDragCoordinator?
    }

    /// An `NSView` that never claims a hit — the reader must not shadow the SwiftUI content it backs.
    final class PassthroughView: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        register(view, context: context)
        return view
    }

    func updateNSView(_ view: PassthroughView, context: Context) {
        // A reused row view can be re-keyed (LazyVStack recycling) — move the registration.
        guard context.coordinator.registeredKey != key else { return }
        if let old = context.coordinator.registeredKey { coordinator.unregister(old) }
        register(view, context: context)
    }

    static func dismantleNSView(_: PassthroughView, coordinator: Coordinator) {
        if let key = coordinator.registeredKey { coordinator.drag?.unregister(key) }
    }

    private func register(_ view: PassthroughView, context: Context) {
        context.coordinator.registeredKey = key
        context.coordinator.drag = coordinator
        coordinator.register(key) { [weak view] in
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        if key == .canvas {
            coordinator.mainWindowFrame = { [weak view] in view?.window?.frame }
        }
    }
}

// MARK: - Cursor-following chip panel

/// A tiny borderless, non-activating, mouse-transparent panel that carries the drag's ghost chip once
/// the cursor leaves the content column (whose SwiftUI overlay clips at the hosting-view edge). Pure
/// AppKit positioning — `setFrameOrigin` per frame, the SwiftUI root swapped only on a destination
/// transition (the caller passes the label/symbol it already resolved).
@MainActor
final class PaneDragChipPanel {
    private var panel: NSPanel?
    private var hosting: NSHostingView<PaneDragChipView>?
    private var lastContent: PaneDragChipView?

    /// Show/move the chip for this frame. Hidden over the canvas — the in-canvas overlay is the
    /// affordance there and a floating twin would double it.
    func update(at screenPoint: CGPoint, drag: PaneDragCoordinator.Drag, label: String, symbol: SFSymbol) {
        if case .canvas = drag.destination {
            hide()
            return
        }
        let content = PaneDragChipView(symbol: symbol, label: label, cancels: drag.destination == .none)
        let panel = ensurePanel()
        if lastContent != content {
            lastContent = content
            hosting?.rootView = content
            if let size = hosting?.fittingSize { panel.setContentSize(size) }
        }
        // The chip trails above-right of the pointer (screen coords are bottom-left origin).
        panel.setFrameOrigin(NSPoint(x: screenPoint.x + 14, y: screenPoint.y + 14))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
        lastContent = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false // the chip capsule draws its own
        created.ignoresMouseEvents = true
        created.level = .popUpMenu // above the workspace + satellites while the drag is live
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PaneDragChipView(symbol: .xmark, label: "", cancels: true))
        created.contentView = host
        hosting = host
        panel = created
        return created
    }
}

/// The floating chip's content — the same capsule voice as `PaneMoveOverlay`'s ghost chip (one drop
/// vocabulary across the canvas overlay and the cross-window panel).
struct PaneDragChipView: View, Equatable {
    let symbol: SFSymbol
    let label: String
    let cancels: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            Text(label)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(cancels ? Slate.Text.tertiary : Slate.Text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            cancels ? Slate.Text.tertiary.opacity(0.4) : Slate.State.accent,
                            lineWidth: 1,
                        ),
                ),
        )
        .shadow(color: Slate.State.shadow, radius: 8, y: 2)
        .fixedSize()
        .padding(6) // keep the shadow inside the borderless panel's bounds
    }
}
#endif
#endif
