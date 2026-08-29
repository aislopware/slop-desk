// ViewEdges — "this view fills its host", as one call instead of five lines, for both shells.
//
// The edge pin is the single most-written shape in an imperative shell: turn the autoresizing mask
// off, then four `constraint(equalTo:)` calls that differ only in which anchor they name.
//
// ⚠️ THIS WAS TYPED TWICE, AND THE REASON GIVEN FOR THAT WAS WRONG. `MacViewEdges.swift` and the
// phone's `Pane/ViewEdges.swift` carried character-identical bodies under a header explaining that
// "`NSLayoutConstraint` and `UILayoutConstraint` are the same name on two frameworks that are not the
// same type, so this cannot descend to the floor". There is no `UILayoutConstraint`: UIKit vends
// `NSLayoutConstraint`, `NSLayoutXAxisAnchor` and `NSLayoutYAxisAnchor` under those exact names, and
// Auto Layout is ONE API on both platforms. The only word in the whole helper that differs between
// the two shells is the host's type — which is what ``SlateHostView`` is. A duplication justified by
// a fact that is not true is the cheapest kind to retire, and the hardest to notice, because the
// header answers the question before anyone asks it.
//
// ⚠️ EDGES, NOT THE SAFE AREA. Everything this pins is INSIDE a controller that has already resolved
// its own insets; a helper that quietly pinned to `safeAreaLayoutGuide` would inset a pane tree twice.
// The one place the safe area is the right anchor (the chip stack's foot) names it at the call site.
//
// Returns the constraints instead of activating them, so a caller that needs to keep one (to animate
// or to swap it later) still can, and a caller that does not writes `NSLayoutConstraint.activate(…)`
// around the call.

// ``SlateHostView`` and its two siblings live in `SlateHostTypes.swift` — this file was where the
// alias was first needed, not where it belongs.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

package extension SlateHostView {
    /// The four constraints that pin this view to every edge of `host`, with the autoresizing mask
    /// already turned off — because a pin whose mask is still on is a pin that silently loses.
    func slateEdges(of host: SlateHostView) -> [NSLayoutConstraint] {
        translatesAutoresizingMaskIntoConstraints = false
        return [
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ]
    }
}
