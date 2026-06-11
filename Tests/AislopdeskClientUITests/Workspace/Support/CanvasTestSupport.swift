import Foundation
import CoreGraphics
@testable import AislopdeskClientUI

// MARK: - Canvas / Workspace test helpers (single-canvas model, docs/31)

extension Canvas {
    /// Builds a canvas from `(id, spec)` pairs, laid out in a non-overlapping row with incrementing z.
    /// Optionally tags every item with `groupID`. The convenience the store / persistence / compact
    /// tests use to construct a multi-pane canvas (was `Tab.canvasTab` / `Tab(root: .split(...))`).
    static func make(
        panes: [(PaneID, PaneSpec)],
        groupID: PaneGroupID? = nil,
        camera: CanvasCamera = .zero
    ) -> Canvas {
        let items = panes.enumerated().map { index, pane in
            CanvasItem(
                id: pane.0,
                spec: pane.1,
                frame: CGRect(x: CGFloat(index) * 700, y: 0, width: 640, height: 420),
                z: index,
                groupID: groupID
            )
        }
        return Canvas(items: items, camera: camera)
    }
}

extension Workspace {
    /// Builds a single-canvas workspace from `(id, spec)` pairs, focused on the first (or `focused`).
    /// The canonical multi-pane fixture (replaces `Workspace(tabs: [Tab.canvasTab(...)], activeTabID:)`).
    static func make(
        panes: [(PaneID, PaneSpec)],
        focused: PaneID? = nil,
        maximized: PaneID? = nil,
        groups: [PaneGroup] = [],
        camera: CanvasCamera = .zero
    ) -> Workspace {
        precondition(!panes.isEmpty, "a canvas workspace fixture needs at least one pane")
        return Workspace(
            canvas: .make(panes: panes, camera: camera),
            focusedPane: focused ?? panes[0].0,
            maximizedPane: maximized,
            groups: groups
        )
    }
}
