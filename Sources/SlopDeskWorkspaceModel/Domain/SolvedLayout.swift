// MARK: - Solved geometry (the focus source of truth)

/// The solved geometry for a tab: every pane's exact rect. This is the **single geometry source of
/// truth** (docs/30 §3) consumed by BOTH the rendered layout AND ``FocusResolver`` — so "move focus
/// left" can never disagree with the pane the user actually sees to the left.
///
/// The frames are the active tab's container-space rects, solved by ``SplitLayoutSolver`` from the
/// tab's split tree — so directional focus reads the same geometry the renderer laid out.
import CoreGraphics
import Foundation

public struct SolvedLayout: Sendable, Equatable {
    public let frames: [PaneID: CGRect]
    public init(frames: [PaneID: CGRect]) {
        self.frames = frames
    }

    /// Empty layout (no panes) — the degenerate base case.
    public static let empty = Self(frames: [:])
}
