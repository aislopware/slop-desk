// PaneDragCoordinator — the cross-container half of the pane move gesture.
//
// The in-canvas drag is confined to one tab's compositor. But the sidebar, the main canvas, and every
// satellite window live in SEPARATE hosting views (`NSSplitViewController` columns / plain
// `NSWindowController`s), so no view framework's coordinate space spans them. This coordinator is the
// shared meeting point: drop targets register lazy SCREEN-rect providers (resolved on demand at drag
// time — nothing publishes per layout pass), the live drag pushes its cursor + resolved destination
// here, and the sidebar/satellite surfaces read the PUBLISHED `drag` to draw their highlights. The
// cursor point itself is `@ObservationIgnored` — observers re-render on destination TRANSITIONS,
// never per pointer frame (the remote-app rule, extended across windows).
//
// Destination vocabulary (``PaneDragDestination``, the superset of the in-canvas ``PaneDropZone``):
//   • `.canvas(zone)`   — the existing swap/re-split/dock inside the main canvas;
//   • `.sidebarRow(p)`  — dropped on a sidebar row → the pane moves BESIDE that row's pane (its tab
//                          revealed) — `moveLeafAcrossTabsTree` / `reattachPaneTree(beside:)`;
//   • `.newTab`         — dropped on the sidebar's New-Tab slot → `breakPaneToTab` / reattach-to-new-tab;
//   • `.tearOff`        — released OUTSIDE the main window → detach into a satellite at the cursor;
//   • `.none`           — dead chrome / the source's own row → release cancels.
// Every commit keeps the `PaneID`, so reconcile never tears a live surface down — the move is pure
// geometry for the terminal / video session.
//
// WHY IT IS HERE AND NOT IN A UI TARGET. Not one line of this class names a view. Three of its
// readers do, and they are in three different places: the SwiftUI canvas, the AppKit navigator rows
// and the AppKit satellite windows. While the class sat in the draining view target that was survivable
// only because `SlopDeskMacUI` imported it (docs/56's Stage D ledger, kind 3); as a value below both
// halves it is simply what a UI asks the drag for, which is the line `SlopDeskClientCore` holds.
//
// WHERE THE PLATFORM LIVES: TWO facts need a pointing, multi-window platform, and both are inside the
// ONE `#if canImport(AppKit)` region at the foot of the class, reached through the three seams it
// publishes — so `update`, `end` and `updateDetachedDrag` read identically on both platforms. The
// facts are `NSEvent.mouseLocation` (the drag it answers for begins in a satellite window, which iOS
// has not got) and steering the navigator's `NSScrollView` under a STATIONARY pointer (a finger
// scrolls the list itself — there is no parked cursor for a heartbeat to serve). The gate is
// `canImport`, not `os(macOS)`: this target compiles for both triples and asks the compiler what the
// platform HAS rather than what it is called.
//
// The CHIP is not in that region, and it used to be. It is a borderless panel that follows the cursor
// across windows, so it is a drawing, and it is drawn one floor up — the coordinator holds a
// ``PaneDragChipSink`` and the UI half fills it, the way docs/56 stage B's notification sinks are
// filled. That is what took the gate from three facts to two: a sink is platform-free, and the phone
// leaves it nil because a touch drag IS its own preview (the finger is on the pane).

import CoreGraphics
import Foundation
import Observation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
#if canImport(AppKit)
import AppKit
#endif

// MARK: - The chip seam

/// The cursor-following drop chip, as a sink. The panel that draws it is a view and lives in a UI
/// target; what the coordinator owns is WHEN it shows and WHAT it says, both of which are decisions.
/// A platform with one window and no cursor leaves this nil rather than implementing an empty one.
@MainActor
package protocol PaneDragChipSink: AnyObject {
    /// Show or move the chip for this drag frame. `label` and `mark` are already resolved by
    /// ``PaneDropRegister``, so the drawing cannot answer "what would this drop do" a second time.
    func showChip(
        at screenPoint: CGPoint, drag: PaneDragCoordinator.Drag, label: String, mark: PaneDropRegister.Mark,
    )
    /// The drag is over (committed or cancelled) — take the chip off screen.
    func hideChip()
}

// MARK: - Coordinator

/// The shared drag rendezvous — created once at app `init` and threaded (like `preferences`) into the
/// sidebar / content columns and every satellite window, none of which share a hosting view.
@MainActor
@Observable
package final class PaneDragCoordinator {
    /// `chip` is handed in at construction rather than assigned later because there is exactly one
    /// place that knows which drawing this app has — the shell that builds the coordinator — and a
    /// settable seam would have invited a second one.
    package init(chip: PaneDragChipSink? = nil) {
        self.chip = chip
    }

    /// The published shape of a live drag. Mutated only when a field CHANGES (destination
    /// transitions), never per cursor frame — observers (row highlights, canvas previews, the New-Tab
    /// slot) re-render on transitions only.
    package struct Drag: Equatable {
        package var source: PaneID
        package var origin: PaneDragOrigin
        package var destination: PaneDragDestination
    }

    /// The live drag, `nil` at rest.
    package private(set) var drag: Drag?

    /// The live cursor (screen coords, AppKit bottom-left origin) — deliberately un-observed: it moves
    /// every frame and only the floating chip consumes it directly.
    @ObservationIgnored private(set) var screenPoint: CGPoint = .zero

    /// The drawing that trails the cursor once it leaves the canvas — see ``PaneDragChipSink``.
    @ObservationIgnored private let chip: PaneDragChipSink?

    /// Lazy screen-rect providers, keyed by target. Resolved on demand at drag time — registration
    /// itself publishes nothing.
    @ObservationIgnored private var providers: [PaneDropTargetKey: () -> CGRect?] = [:]

    /// The main workspace window's frame — the `.tearOff` boundary. Registered by the canvas reader
    /// (the one drop target guaranteed to live in the main window).
    @ObservationIgnored package var mainWindowFrame: () -> CGRect? = { nil }

    /// The ACTIVE tab's solved leaf rects + container bounds (canvas-local, top-left) — pushed by the
    /// canvas compositor so a satellite-origin drag resolves canvas zones without a live view closure.
    @ObservationIgnored package var canvasFrames: [PaneID: CGRect] = [:]
    @ObservationIgnored package var canvasBounds: CGRect = .zero

    /// Screen points recorded at a `.tearOff` commit, consumed by the satellite-window coordinator to
    /// place the new window under the drop instead of the centre-cascade.
    @ObservationIgnored private var pendingPlacements: [PaneID: CGPoint] = [:]

    /// The live store — chip labels + the sole-leaf `.newTab` gate read it. Weak: the coordinator is
    /// app-lifetime glue, never an owner.
    @ObservationIgnored package weak var store: WorkspaceStore?

    /// Whether the live TREE drag's source is the sole leaf of its tab — stashed per frame so the
    /// auto-scroll tick can re-resolve the external destination without re-asking the canvas.
    @ObservationIgnored private var treeSourceIsSoleLeaf = false

    /// The armed spring-load: hovering a sidebar row for the dwell REVEALS that row's tab (Finder-style
    /// spring-loaded folders), so the drag can continue into the newly shown canvas and drop precisely.
    @ObservationIgnored private let springLoadTask = DeadlineLatch()
    @ObservationIgnored private var springLoadArmedRow: PaneID?

    /// Sidebar-row dwell before the spring-loaded tab reveal fires.
    static let springLoadDwell: Duration = .milliseconds(500)

    // MARK: Target registry

    package func register(_ key: PaneDropTargetKey, provider: @escaping () -> CGRect?) {
        providers[key] = provider
    }

    package func unregister(_ key: PaneDropTargetKey) {
        providers[key] = nil
    }

    package func targetFrame(_ key: PaneDropTargetKey) -> CGRect? {
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
    /// changed, move the chip, and (re-)arm the spring-load + edge auto-scroll.
    package func update(
        source: PaneID,
        origin: PaneDragOrigin,
        screenPoint point: CGPoint,
        destination: PaneDragDestination,
        sourceIsSoleLeafOfItsTab: Bool = false,
    ) {
        screenPoint = point
        treeSourceIsSoleLeaf = sourceIsSoleLeafOfItsTab
        let next = Drag(source: source, origin: origin, destination: destination)
        if drag != next { drag = next }
        armSpringLoad(for: destination)
        platformDragFrame(at: point)
        chip?.showChip(
            at: point,
            drag: next,
            label: chipLabel(for: next),
            mark: PaneDropRegister.mark(for: destination),
        )
    }

    /// Ends the drag and returns the final destination for the commit — one call from the release.
    package func takeDestination() -> PaneDragDestination {
        let destination = drag?.destination ?? .none
        end()
        return destination
    }

    /// Clears the drag (cancel path — a commit goes through ``takeDestination()``).
    package func end() {
        if drag != nil { drag = nil }
        cancelSpringLoad()
        platformDragEnded()
        chip?.hideChip()
    }

    // MARK: Spring-loaded tab reveal (dwell on a sidebar row → its tab becomes the canvas)

    /// Arm / re-arm / cancel the spring-load for this frame's `destination`. Hovering ONE row for the
    /// dwell selects that row's tab — the drag keeps going and can now drop into the revealed canvas.
    /// The dwell re-arms on every row TRANSITION (sweeping down the list never fires), and the fire
    /// re-checks the published destination so a row the cursor already left can't switch tabs late.
    private func armSpringLoad(for destination: PaneDragDestination) {
        guard case let .sidebarRow(row) = destination else {
            cancelSpringLoad()
            return
        }
        guard row != springLoadArmedRow else { return }
        springLoadArmedRow = row
        springLoadTask.arm(after: Self.springLoadDwell) { [weak self] in
            guard let self else { return }
            guard drag?.destination == .sidebarRow(row), let store else { return }
            if let index = Self.springLoadTabIndex(for: row, in: store.tree) {
                store.selectTab(index)
            }
        }
    }

    private func cancelSpringLoad() {
        springLoadTask.cancel()
        springLoadArmedRow = nil
    }

    /// The tab index a spring-load on `row` should reveal: the ACTIVE session's tab owning that pane,
    /// `nil` when it is already the active tab (nothing to reveal) or the pane is not in the active
    /// session's tree (a detached pane's row — no tab to spring to). Pure + static so the reveal rule
    /// is pinned headlessly.
    static func springLoadTabIndex(for row: PaneID, in tree: TreeWorkspace) -> Int? {
        guard let session = tree.activeSession,
              let index = session.tabIndex(containing: row),
              index != session.activeTabIndex
        else { return nil }
        return index
    }

    /// One drag frame for a DETACHED (satellite grab strip) drag: the cursor is the global mouse
    /// location; canvas zones resolve from the pushed solved layout (insert semantics — no swap), the
    /// rest from the registered external targets.
    package func updateDetachedDrag(source: PaneID) {
        // The gesture lives in the SATELLITE's window, so its own location stream is that window's,
        // not the workspace's — the only cursor that spans both is the platform's. No platform
        // cursor means no satellite window either, so there is nothing to update rather than a
        // point to guess at (``PaneDragResolver/externalDestination(at:targets:origin:source:sourceIsSoleLeafOfItsTab:)``
        // would happily resolve a tear-off from a fabricated origin).
        guard let point = Self.platformCursorLocation() else { return }
        update(
            source: source, origin: .detached, screenPoint: point,
            destination: resolveDetachedDestination(at: point, source: source),
        )
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
    /// bounds — the canvas zones stay the compositor's own live resolution.
    package func resolveTreeExternalDestination(
        at point: CGPoint, source: PaneID, sourceIsSoleLeafOfItsTab: Bool,
    ) -> PaneDragDestination {
        PaneDragResolver.externalDestination(
            at: point, targets: externalTargets(), origin: .tree, source: source,
            sourceIsSoleLeafOfItsTab: sourceIsSoleLeafOfItsTab,
        )
    }

    /// The destination a TREE drag resolves once its source's tab is NO LONGER the active tab (a
    /// spring-loaded reveal switched tabs mid-drag): the visible canvas is another tab's, so its zones
    /// resolve with INSERT semantics against the pushed active-tab layout — exactly the satellite case
    /// (the source isn't in this tab; no swap, no self to exclude). Everything off the canvas keeps the
    /// tree-drag external precedence (tear-off stays available — it is still a tree pane leaving).
    package func resolveSpringLoadedTreeDestination(
        at point: CGPoint, source: PaneID, sourceIsSoleLeafOfItsTab: Bool,
    ) -> PaneDragDestination {
        if let canvas = targetFrame(.canvas), canvas.contains(point) {
            let local = PaneDragResolver.canvasLocal(fromScreen: point, canvas: canvas)
            let zone = PaneDragResolver.insertZone(at: local, frames: canvasFrames, container: canvasBounds)
            return zone == .none ? .none : .canvas(zone)
        }
        return resolveTreeExternalDestination(
            at: point, source: source, sourceIsSoleLeafOfItsTab: sourceIsSoleLeafOfItsTab,
        )
    }

    // MARK: - The platform half of a live drag

    // ⚠️ ONE GATE, AND THIS IS IT. Everything the drag needs a POINTING, MULTI-WINDOW platform for
    // lives inside this region and is reached through the three seams it publishes, so the lifecycle
    // above reads identically on both platforms. It used to be four gates — the stored properties up
    // in the property block, a pair inside those lifecycle methods, and this section — which is four
    // places for one fact to drift.
    //
    // The two facts here have no iOS spelling to find, not merely no port: `NSEvent.mouseLocation`
    // (the drag it answers for begins in a satellite window, which iOS also has not got), and
    // steering the navigator's `NSScrollView` under a STATIONARY pointer (a finger scrolls the list
    // itself — there is no parked cursor for a heartbeat to serve). The shape is `SlateCancelKey`'s
    // and docs/56 §3.5's: a platform seam is a SINK, not an `#if` at the call site.

    #if canImport(AppKit)

    /// The sidebar list's enclosing `NSScrollView` — resolved lazily (registered by a reader INSIDE the
    /// scroll content; the viewport reader outside it cannot reach the scroller). Drives the drag
    /// edge-band auto-scroll. Down here with the code that reads it rather than up in the property
    /// block, so the gate stays one region.
    @ObservationIgnored package var sidebarScrollProvider: () -> NSScrollView? = { nil }

    /// The auto-scroll heartbeat — runs only while the drag cursor sits in the list's edge band, so a
    /// STATIONARY cursor keeps scrolling (per-pointer-frame stepping alone would stall the moment the
    /// hand stops).
    @ObservationIgnored private var autoScrollTimer: Timer?

    /// The global cursor, in screen coordinates — the one location a gesture in ANOTHER window can be
    /// resolved against. `nil` where the platform has no such thing.
    static func platformCursorLocation() -> CGPoint? { NSEvent.mouseLocation }

    /// One drag frame's platform work: steer the edge auto-scroll. It reads the frame the caller
    /// already published, so it cannot disagree with it.
    private func platformDragFrame(at point: CGPoint) {
        updateAutoScroll(at: point)
    }

    /// The drag is over (committed or cancelled): stop the heartbeat.
    private func platformDragEnded() {
        stopAutoScroll()
    }

    // MARK: Sidebar edge auto-scroll (rows outside the viewport become reachable mid-drag)

    /// Start/steer/stop the auto-scroll heartbeat for this frame's cursor. The timer (not the pointer
    /// stream) does the stepping, so a cursor PARKED in the band keeps scrolling.
    private func updateAutoScroll(at point: CGPoint) {
        guard drag != nil,
              let list = targetFrame(.sidebarList),
              PaneDragResolver.autoScrollStep(at: point, list: list) != nil,
              sidebarScrollProvider() != nil
        else {
            stopAutoScroll()
            return
        }
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Timer on the main run loop fires on the main thread; hop the actor boundary explicitly.
            MainActor.assumeIsolated { self?.autoScrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common) // .common: keep scrolling while the drag tracks
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// One heartbeat: re-derive the step from the CURRENT cursor (it may have left the band), scroll the
    /// clip view, then re-resolve the destination — the rows moved under a stationary cursor, so the
    /// highlight must follow without waiting for the next pointer frame.
    private func autoScrollTick() {
        guard drag != nil,
              let scroll = sidebarScrollProvider(),
              let list = targetFrame(.sidebarList),
              let step = PaneDragResolver.autoScrollStep(at: screenPoint, list: list)
        else {
            stopAutoScroll()
            return
        }
        let clip = scroll.contentView
        let maxOffset = Double.maximum(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = Double.minimum(Double.maximum(0, origin.y + step), maxOffset)
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        refreshDestinationUnderCursor()
    }

    /// Re-resolve the live drag's destination at the stashed cursor after an auto-scroll step. The
    /// cursor is inside the sidebar list here, so a tree drag can only resolve EXTERNAL destinations —
    /// the canvas' own live resolution is never bypassed.
    private func refreshDestinationUnderCursor() {
        guard let drag else { return }
        let destination: PaneDragDestination =
            switch drag.origin {
            case .detached:
                resolveDetachedDestination(at: screenPoint, source: drag.source)
            case .tree:
                resolveTreeExternalDestination(
                    at: screenPoint, source: drag.source, sourceIsSoleLeafOfItsTab: treeSourceIsSoleLeaf,
                )
            }
        update(
            source: drag.source, origin: drag.origin, screenPoint: screenPoint,
            destination: destination, sourceIsSoleLeafOfItsTab: treeSourceIsSoleLeaf,
        )
    }

    #else

    /// No cursor to ask — see the region header. The caller treats `nil` as "no satellite drag to
    /// resolve", which is the truth on a device with one window.
    static func platformCursorLocation() -> CGPoint? { nil }

    /// A touch drag IS its own preview (the finger is on the pane), and there is no parked pointer for
    /// an auto-scroll heartbeat to serve. Empty, not unported.
    private func platformDragFrame(at _: CGPoint) {}

    private func platformDragEnded() {}

    #endif

    // MARK: Tear-off placement hand-off

    package func recordPlacement(_ pane: PaneID, at point: CGPoint) {
        pendingPlacements[pane] = point
    }

    package func takePlacement(for pane: PaneID) -> CGPoint? {
        pendingPlacements.removeValue(forKey: pane)
    }

    // MARK: Chip content

    /// The chip's action label, in the ONE drop register both chips read (``PaneDropRegister``). The
    /// only thing resolved here is the NAME the register interpolates, because that needs the live
    /// store: off the canvas the sentence is about the pane the cursor is OVER, not the one in hand.
    private func chipLabel(for drag: Drag) -> String {
        var targetTitle: String?
        if case let .sidebarRow(target) = drag.destination {
            let spec = store?.tree.activeSession?.specs[target]
            targetTitle = RailRowsBuilder.rowTitle(kind: spec?.kind ?? .terminal, spec: spec)
        }
        return PaneDropRegister.label(
            for: drag.destination, targetTitle: targetTitle, origin: drag.origin,
        )
    }
}
