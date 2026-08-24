// PaneDropRegister — the near-side FACE of `slopdesk_workspace::drop_register`.
//
// Two chips say what a release would do, and they are the same chip: the canvas overlay's ghost chip
// pinned to the cursor inside the compositor, and the borderless panel that takes over the moment the
// cursor leaves the content column's hosting view (which clips the overlay). Both were documented as
// "the same capsule voice — one drop vocabulary", and both spelled that vocabulary out for
// themselves. Two switches for one register is one place for the words to drift, and it drifts
// SILENTLY — the two chips are never on screen at the same instant, so nobody can see them disagree.
//
// The register answers over BOTH vocabularies on purpose. ``PaneDragDestination`` is the
// cross-container superset and ``PaneDropZone`` its in-canvas half, and the two chips genuinely ask
// different questions: over the canvas the answer names the ZONE ("swap main", "split left"), and off
// it the answer names the CONTAINER the pane is going to ("move beside api", "new window"). Folding
// those into one enum would have been a translation layer pretending to be a decision.
//
// THE MARK IS SEMANTIC, NOT AN `SFSymbol`. `SFSafeSymbols` is a dependency of `SlopDeskSlate` and of
// the two UI targets, and deliberately not of this one — the reading floor names no artwork. So the
// register answers with a ``Mark`` and each drawing maps it to its own image type in exactly one
// place. The alternative was a dependency edge bought to carry five glyph names.
//
// THE MARK AND THE SENTENCE CROSS TOGETHER, and that is correctness rather than economy: the canvas
// destination's label is deliberately EMPTY, so a words-only door would answer `docs/55` §4's `0` for
// it and be indistinguishable from "no such destination". With the mark byte in front the delivery is
// never empty, and `0` keeps its one meaning.

import CSlopDeskFFI
import Foundation

/// The wording and the mark every pane-drop chip draws from.
package enum PaneDropRegister {
    /// What a drop chip's glyph MEANS. Named for the outcome rather than for any icon set's spelling
    /// of it, so a renderer maps it once and neither half can grow an eighth mark on its own.
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

        /// The mark `code` names. A byte no mark has is the cancel, which is the one outcome that is
        /// safe to draw for a drop nobody recognises.
        init(code: UInt8) {
            switch code {
            case 1: self = .swap
            case 2: self = .splitColumns
            case 3: self = .splitRows
            case 4: self = .beside
            case 5: self = .newTab
            case 6: self = .newWindow
            default: self = .cancel
            }
        }
    }

    // MARK: In-canvas (the overlay's ghost chip)

    /// The in-canvas chip's label — verb first, then what the verb acts on.
    package static func label(for zone: PaneDropZone, title: String?) -> String {
        chip(for: zone, title: title).label
    }

    /// The in-canvas chip's mark. A re-split and a dock draw the same split silhouette — what differs
    /// between them is the SIZE of the preview underneath, not the shape of the outcome.
    package static func mark(for zone: PaneDropZone) -> Mark {
        chip(for: zone, title: nil).mark
    }

    /// One crossing for the zone chip. `title` is the DRAGGED pane's; an absent or blank one falls
    /// back to the anonymous name on the far side, so the two chips cannot pick different fallbacks.
    private static func chip(for zone: PaneDropZone, title: String?) -> (mark: Mark, label: String) {
        let (kind, edge): (UInt8, UInt8) =
            switch zone {
            case .none: (0, 0)
            case .swap: (1, 0)
            case let .resplit(_, edge): (2, edge.byte)
            case let .dock(edge): (3, edge.byte)
            }
        return delivered(title) { bytes, present, out, cap in
            Int(slopdesk_ws_drop_zone(kind, edge, bytes, title?.utf8.count ?? 0, present, out, cap))
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
        chip(for: destination, targetTitle: targetTitle, origin: origin).label
    }

    /// The floating chip's mark. `.canvas` answers `.swap` and is never drawn — the chip is hidden
    /// over the canvas — so the case exists to keep the answer total rather than to pick a glyph.
    package static func mark(for destination: PaneDragDestination) -> Mark {
        chip(for: destination, targetTitle: nil, origin: .tree).mark
    }

    /// One crossing for the floating chip. The origin decides which of two words the sentence uses —
    /// a satellite MERGES back into the tree, a tiled pane MOVES within it.
    private static func chip(
        for destination: PaneDragDestination, targetTitle: String?, origin: PaneDragOrigin,
    ) -> (mark: Mark, label: String) {
        let kind: UInt8 =
            switch destination {
            case .canvas: 0
            case .sidebarRow: 1
            case .newTab: 2
            case .tearOff: 3
            case .none: 4
            }
        let detached = origin == .detached
        return delivered(targetTitle) { bytes, present, out, cap in
            Int(slopdesk_ws_drop_destination(
                kind, detached, bytes, targetTitle?.utf8.count ?? 0, present, out, cap,
            ))
        }
    }

    /// Reads one `[u8 mark]` + one run delivery, with `title` borrowed for the length of the call.
    ///
    /// The retry lives inside the title's scope rather than around it: `door` is pure, so the second
    /// ask cannot disagree with the first, and the borrowed bytes stay live across both.
    private static func delivered(
        _ title: String?,
        _ door: (UnsafePointer<UInt8>?, Bool, UnsafeMutablePointer<UInt8>?, Int) -> Int,
    ) -> (mark: Mark, label: String) {
        let bytes = Array((title ?? "").utf8)
        let blob = bytes.withUnsafeBufferPointer { borrowed in
            wsAnswerBytes { out, cap in door(borrowed.baseAddress, title != nil, out, cap) }
        }
        guard let mark = blob.first else { return (.cancel, "") }
        return (Mark(code: mark), wsRuns(Array(blob.dropFirst()), count: 1)[0])
    }
}
