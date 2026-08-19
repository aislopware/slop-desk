// PanePointer — what the pointer should SAY over a piece of pane chrome, as a value.
//
// SwiftUI's `PointerStyle` is `@available(iOS, unavailable)` OUTRIGHT — not "unavailable before 18",
// not "empty on a phone": the type does not exist on the iOS triple and neither does the
// `.pointerStyle(_:)` modifier (checked against the iOS 26 SDK's `SwiftUI.swiftinterface`). AppKit
// spells the same thing again as `NSCursor`. So there is no shared API to find, only a gate that must
// exist EXACTLY ONCE — and the one place a gate cannot drift to is a target with no framework in it.
//
// The defect the value prevents is worse than the gate count. ``PaneDivider``'s pointer carries a
// DECISION (which way a seam at its min-weight clamp can still travel), and a decision written inside
// a platform gate is a decision nobody reads on the other platform. Stated as a value it is plain
// Swift everywhere, and only the DRAWING is gated — one `PointerStyle` switch in the SwiftUI half,
// one `NSCursor` switch in the AppKit half when the canvas crosses.
//
// The truth-at-the-clamp rule lives with the RENDERER rather than here: a seam that can still move
// both ways and a DEAD seam that can move neither both keep the two-way glyph, because there is no
// "cannot resize" pointer and a plain arrow over a seam reads as a dead zone rather than as a seam
// sitting on its floor.

/// What the pointer should SAY over a piece of pane chrome.
package enum PanePointer: Equatable {
    /// The pane-move grab handle, hovered but not yet grabbed.
    case grabIdle
    /// The pane-move grab handle with the drag in flight.
    case grabActive
    /// A vertical seam between side-by-side panes. The flags are the directions the drag can still
    /// travel — see ``PaneDivider`` — which the handle's pair weights answer, so the glyph can never
    /// disagree with the gesture's own clamp.
    case columnResize(toLeading: Bool, toTrailing: Bool)
    /// A horizontal seam between stacked panes, with the same two directions turned a quarter turn.
    case rowResize(toUp: Bool, toDown: Bool)
}
