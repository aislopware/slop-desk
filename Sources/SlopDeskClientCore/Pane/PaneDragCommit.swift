// PaneDragCommit — the ONE store op a cross-container release commits.
//
// A pane that leaves the canvas can land in four places — beside a leaf in another tab's canvas, on
// that canvas's outer edge, beside a navigator row's pane, or in a tab of its own — and the same four
// were spelled twice: once in the canvas compositor's `commitDestination` (the spring-loaded landing,
// where a reveal switched tabs mid-drag and the source is no longer in the visible tab) and once in
// the satellite window's grab strip, whose own header called itself "the reattach twin of
// `SplitContainer.commitDestination`". Two spellings of one decision, in two files, one of which is
// about to be rewritten in AppKit.
//
// WHAT DIFFERS BETWEEN THE TWO IS THE OP FAMILY, AND THE FAMILY IS THE ORIGIN. A pane still in a
// tab's tree MOVES across tabs; a detached pane REATTACHES into one. Both keep the `PaneID` — that is
// the whole point of every path here, since a torn-down surface would drop the live PTY or re-hello
// the video session — so the pair differs only in which of the two ops the tree layer already
// publishes it calls. ``PaneDragOrigin`` is exactly that bit and already rides on every published
// drag, so the caller passes what it already has rather than a second enum meaning the same thing.
//
// WHAT IS NOT HERE, AND WHY. `.canvas` for a source that IS in the visible tab stays with the canvas:
// a swap, an in-tab re-split and an in-tab dock are that compositor's own vocabulary and no other
// surface can commit them. `.tearOff` stays with it too, because a tear-off is two ordered steps
// rather than one op — the drop point is recorded FIRST, so the satellite coordinator finds it when
// the detach's synchronous `detachedPanes` change opens the window — and folding an ordering into a
// shared switch would hide it from both readers.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The commit half of a cross-container pane drag: one destination in, exactly ONE store op out.
@MainActor
package enum PaneDragCommit {
    /// Commits `destination` for `pane`, in the op family `origin` names. Exactly one store op fires
    /// (so the layout / terminal-grid / remote-window redraw happens once, on release, not per drag
    /// frame) and every path keeps the `PaneID`.
    ///
    /// The cases that are NOT this function's — an in-tab `.canvas` zone, `.tearOff`, `.none`, and the
    /// `.canvas(.swap)`/`.canvas(.none)` an insert resolution can never produce — do nothing here, so
    /// a caller may hand over a whole destination and keep only the ones it genuinely owns.
    package static func commit(
        _ destination: PaneDragDestination,
        pane: PaneID,
        origin: PaneDragOrigin,
        in store: WorkspaceStore,
    ) {
        switch destination {
        case let .canvas(.resplit(target, edge)):
            switch origin {
            case .tree:
                store.moveLeafAcrossTabsTree(pane, beside: target, axis: edge.axis, before: edge.insertsBefore)
            case .detached:
                store.reattachPaneTree(pane, beside: target, axis: edge.axis, before: edge.insertsBefore)
            }
        case let .canvas(.dock(edge)):
            switch origin {
            case .tree: store.moveLeafToActiveTabRootEdgeTree(pane, edge: edge)
            case .detached: store.reattachPaneToActiveTabRootEdgeTree(pane, edge: edge)
            }
        case let .sidebarRow(anchor):
            // A row drop always lands BESIDE, along the horizontal axis and after the anchor: the row
            // says WHICH pane, not which side of it — there is no edge in a list.
            switch origin {
            case .tree:
                store.moveLeafAcrossTabsTree(pane, beside: anchor, axis: .horizontal, before: false)
            case .detached:
                store.reattachPaneTree(pane, beside: anchor, axis: .horizontal, before: false)
            }
        case .newTab:
            switch origin {
            case .tree: store.breakPaneToTab(pane)
            case .detached: store.reattachPaneToNewTabTree(pane)
            }
        case .canvas,
             .tearOff,
             .none:
            break
        }
    }
}
