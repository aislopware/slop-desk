// PaneDropRegister — the one register a pane drop is announced in.
//
// Two chips say what a release would do, and they are the same chip: the canvas overlay's ghost chip
// pinned to the cursor inside the compositor, and the borderless panel that takes over the moment the
// cursor leaves the content column's hosting view (which clips the overlay). Both were documented as
// "the same capsule voice — one drop vocabulary", and both spelled that vocabulary out for
// themselves: `PaneMoveOverlay.zoneLabel`/`zoneIcon` over ``PaneDropZone``, and the coordinator's own
// `chipLabel`/`chipSymbol` over ``PaneDragDestination``. Two switches for one register is one place
// for the words to drift, and it drifts SILENTLY — the two chips are never on screen at the same
// instant, so nobody can see them disagree.
//
// The register answers over BOTH vocabularies on purpose. `PaneDragDestination` is the cross-container
// superset and `PaneDropZone` its in-canvas half, and the two chips genuinely ask different
// questions: over the canvas the answer names the ZONE ("swap main", "split left"), and off it the
// answer names the CONTAINER the pane is going to ("move beside api", "new window"). Folding those
// into one enum would have been a translation layer pretending to be a decision.
//
// THE MARK IS SEMANTIC, NOT AN `SFSymbol`. `SFSafeSymbols` is a dependency of `SlopDeskSlate` and of
// the two UI targets, and deliberately not of this one — the presentation floor names no artwork. So
// the register answers with a ``Mark`` and each drawing maps it to its own image type in exactly one
// place. The alternative was a dependency edge bought to carry five glyph names.

import SlopDeskWorkspaceModel

/// The wording and the mark every pane-drop chip draws from.
package enum PaneDropRegister {
    /// What a drop chip's glyph MEANS. Named for the outcome rather than for any icon set's spelling
    /// of it, so a renderer maps it once and neither half can grow a sixth mark on its own.
    package enum Mark: Equatable {
        /// Releasing here commits nothing.
        case cancel
        /// The two panes exchange places.
        case swap
        /// The drop forms COLUMNS — a `.horizontal` split, panes side by side.
        case splitColumns
        /// The drop forms ROWS — a `.vertical` split, panes stacked.
        case splitRows
        /// The pane lands beside another pane's row, in that row's tab.
        case beside
        /// The pane becomes a tab of its own.
        case newTab
        /// The pane becomes a window of its own.
        case newWindow
    }

    /// The name a chip falls back to when the dragged pane has no title worth printing. A pane always
    /// has SOMETHING to be called, and "pane" reads better than an empty gap in the middle of a verb
    /// phrase.
    package static let anonymousPaneName = "pane"

    // MARK: In-canvas (the overlay's ghost chip)

    /// The in-canvas chip's label — verb first, then what the verb acts on.
    package static func label(for zone: PaneDropZone, title: String?) -> String {
        let name = name(from: title)
        switch zone {
        case .none: return "cancel"
        case .swap: return "swap \(name)"
        case let .resplit(_, edge): return "split \(edge.rawValue)"
        case let .dock(edge): return "dock \(edge.rawValue)"
        }
    }

    /// The in-canvas chip's mark. A re-split and a dock draw the same split silhouette — what differs
    /// between them is the SIZE of the preview underneath, not the shape of the outcome.
    package static func mark(for zone: PaneDropZone) -> Mark {
        switch zone {
        case .none: .cancel
        case .swap: .swap
        case let .resplit(_, edge): mark(forSplitOn: edge)
        case let .dock(edge): mark(forSplitOn: edge)
        }
    }

    // MARK: Cross-container (the cursor-following panel)

    /// The floating chip's label. `targetTitle` is the pane the cursor is over (a sidebar row's), NOT
    /// the dragged pane — off the canvas the sentence is about where the pane is GOING. The `.canvas`
    /// case answers with an empty string because the chip hides there: the in-canvas overlay is the
    /// affordance, and a floating twin over it would double the same words.
    package static func label(
        for destination: PaneDragDestination, targetTitle: String?, origin: PaneDragOrigin,
    ) -> String {
        switch destination {
        case .canvas:
            return ""
        case .sidebarRow:
            let name = name(from: targetTitle)
            // A satellite MERGES back into the tree; a tiled pane MOVES within it. Same op, and the
            // two words are the only thing that tells the user which one they are doing.
            return origin == .detached ? "merge beside \(name)" : "move beside \(name)"
        case .newTab:
            return "new tab"
        case .tearOff:
            return "new window"
        case .none:
            return "cancel"
        }
    }

    /// The floating chip's mark. `.canvas` answers `.swap` and is never drawn — the chip is hidden
    /// over the canvas — so the case exists to keep the switch total rather than to pick a glyph.
    package static func mark(for destination: PaneDragDestination) -> Mark {
        switch destination {
        case .canvas: .swap
        case .sidebarRow: .beside
        case .newTab: .newTab
        case .tearOff: .newWindow
        case .none: .cancel
        }
    }

    // MARK: -

    /// `.left`/`.right` partition WIDTH and make columns; `.top`/`.bottom` partition HEIGHT and make
    /// rows. Read off ``PaneDropEdge/axis`` rather than re-listing the four cases, so the mark cannot
    /// disagree with the tree op the same edge drives.
    private static func mark(forSplitOn edge: PaneDropEdge) -> Mark {
        edge.axis == .horizontal ? .splitColumns : .splitRows
    }

    private static func name(from title: String?) -> String {
        guard let title, !title.isEmpty else { return anonymousPaneName }
        return title
    }
}
