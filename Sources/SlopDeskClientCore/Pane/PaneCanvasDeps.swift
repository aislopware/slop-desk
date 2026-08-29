// PaneCanvasDeps — the canvas cluster's INJECTION LIST, as one value instead of four parameters
// repeated on every view in the cluster.
//
// The four things a pane surface needs from the app are the same four everywhere below the content
// column: the ``WorkspaceStore`` it mutates, the ``PaneDragCoordinator`` a cross-window pane move
// resolves against, the ``OverlayCoordinator`` a context action summons through, and the
// ``WorkspaceChromeState`` a chrome-aware surface reads. Every view in the cluster — the content
// canvas, the split canvas, its per-tab layer, the pane container — declared all four as stored
// properties and took all four as init parameters, which is the same eight lines written eight times.
// That is not incidental duplication: it is the SAME LIST, and a list is a value.
//
// WHY A STRUCT AND NOT A PROTOCOL. Nothing here is substituted — a preview passes the same four
// objects a shipping mount does, with `nil` where a surface genuinely has no coordinator (a satellite
// window has no chrome; iOS has no cross-window drag). An existential would buy a seam nobody uses and
// cost a dynamic dispatch on the hottest wiring path in the tree.
//
// WHY ONE TYPE FOR THE WHOLE CLUSTER rather than one per view. A per-view deps type would be four
// near-identical structs, which is the duplication moved rather than removed, and it would force a
// re-pack at every level (`PaneCanvasDeps` → `PaneContainerDeps`) where today the value is simply
// passed along. The parameters that are NOT shared stay parameters: `connection` and `onConnect` are
// the content canvas's alone (a satellite pane content has no connection to show and no Connect
// editor to open), and `paneID` / `isFocused` / `isVisible` are per-pane facts, not dependencies.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The four app-lifetime objects every pane surface is handed.
@MainActor
package struct PaneCanvasDeps {
    /// The workspace store every mutation lands in.
    package let store: WorkspaceStore
    /// The cross-window pane-move coordinator, or `nil` where there is no second window (iOS, previews).
    package let paneDrag: PaneDragCoordinator?
    /// The overlay summoner (Connect editor, palette, sheets), or `nil` in a preview.
    package let overlay: OverlayCoordinator?
    /// The window chrome's live state, or `nil` in a satellite window that has none.
    package let chrome: WorkspaceChromeState?

    package init(
        store: WorkspaceStore,
        paneDrag: PaneDragCoordinator? = nil,
        overlay: OverlayCoordinator? = nil,
        chrome: WorkspaceChromeState? = nil,
    ) {
        self.store = store
        self.paneDrag = paneDrag
        self.overlay = overlay
        self.chrome = chrome
    }

    /// The LIVE session behind `paneID`, or `nil` for a pane whose handle is not a live session (a
    /// placeholder, a torn-out pane mid-flight). Both shells asked the store this exact question with
    /// the exact same conditional cast, in four places each.
    package func liveSession(_ paneID: PaneID) -> LivePaneSession? {
        store.handle(for: paneID) as? LivePaneSession
    }
}

/// What a split divider's four gestures DO — the store calls, without the drawing.
///
/// The seam view owns the gesture (a pan on iOS, a tracking loop on macOS); what a step, a release and
/// a double-tap MEAN is one policy, and it was written out twice as four inline closures over `store`
/// and `handle`. Stated here, each shell's call site is four one-line forwards.
@MainActor
package enum PaneDividerActions {
    /// The seam took the grip: suspend terminal reflow for the whole drag, so a 60 Hz drag does not
    /// spend a host round trip per sample.
    package static func begin(_ store: WorkspaceStore) {
        store.setTerminalResizeSuspended(true)
    }

    /// A drag step landed on `leadingWeight` — live, uncommitted.
    package static func change(
        _ store: WorkspaceStore, _ handle: SplitTreeRenderModel.DividerHandle, _ leadingWeight: Double,
    ) {
        store.setDividerWeightLive(
            splitID: handle.splitID,
            leadingChildIndex: handle.childIndex,
            leadingWeight: leadingWeight,
        )
    }

    /// The grip released: unsuspend reflow and commit the weight the drag left behind. ORDER MATTERS —
    /// the commit arms the model's reflow signal, and unsuspending after it would drop the first frame.
    package static func end(_ store: WorkspaceStore) {
        store.setTerminalResizeSuspended(false)
        store.commitDividerResize()
    }

    /// A double-tap on the seam: even this split's children, without a suspend/commit round trip.
    package static func reset(_ store: WorkspaceStore, _ handle: SplitTreeRenderModel.DividerHandle) {
        store.evenDividerTree(
            splitID: handle.splitID, leadingChildIndex: handle.childIndex,
        )
    }
}
