// PaneResizeScrimState — "is this pane mid-resize", as a value rather than four `@State` flags.
//
// While a pane is being resized its surface is the WRONG pixels: a terminal is a frozen grid stretched
// to a size the host has not reflowed to yet, a remote window is a scaled last frame. The scrim covers
// that moment so it reads as a deliberate "resizing" state instead of a glitchy stretch. Deciding WHEN
// it is up is a small state machine over three signals that arrive at different times, and it lived as
// `@State private var resizing / settledSize / resizedDuringDrag` inside the pane container — a
// reducer spelled in view storage, which is exactly the shape docs/56 §3 says leaves the UI target.
//
// THE THREE SIGNALS, AND WHY NONE OF THEM IS ENOUGH ALONE:
//   • GEOMETRY settle — `size` changed, so something resized this pane, whatever the source (a divider
//     commit, a window edge, a sidebar, a split add/remove, a zoom, a balance, a tab switch). It STARTS
//     the scrim and self-clears after `settle`. On its own it is only a TIMER proxy for "re-rendered".
//   • DRAG hold — the geometry timer clears after 200 ms, but an interactive drag defers its host send
//     to release, so a PAUSED drag (mouse held, cursor still) has no reflow armed yet and would flash
//     through the gap. Sticky for the drag's duration, and gated on this pane having actually changed
//     size so it never dims panes nobody is dragging.
//   • REFLOW hold — the model's `awaitingResizeReflow`: the real "fresh pixels landed" signal. It holds
//     the scrim across the host round trip, which on a slow link outlasts the geometry timer by ~1 RTT.
//
// MOUNT IS NOT A RESIZE. A change between two NON-ZERO sizes is a resize; a change to or from `.zero`
// is the initial layout settling or a teardown, and flashing the scrim on every pane at launch is the
// regression this rule exists to stop.
//
// The `.task(id: size)` timer stays in the view — a sleep is the framework's, not the reducer's. What
// crosses is the two edges (`noteSize`, `noteSettled`) and the drag-ended edge.
//
// THERE WAS A FOURTH INPUT AND IT WAS NEVER SET. `isVisible` took a `staticMirror` flag that short-
// circuited it to `false` for a headless `ImageRenderer` snapshot pass. Nothing ever passed `true`:
// the flag entered the canvas as a defaulted `SplitContainer` parameter, was threaded down through
// `PaneContainer` to both leaves, and every caller in `Sources/`, `Apps/` and `ThirdParty/` took the
// default. Only three unit tests — this file's neighbours — ever produced the value, so the branch
// was a path that existed to be tested. It is gone (increment 56d), and `check-supervisor.sh` keeps
// it gone; a snapshot path that comes back gets ONE gate at the render root, not a flag every
// predicate below the canvas has to carry.

import CoreGraphics
import Foundation

/// The pane resize scrim's reducer. Inputs are edges; ``isVisible(isDragging:awaitingReflow:)`` is
/// the answer.
package struct PaneResizeScrimState: Equatable, Sendable {
    /// How long `size` must hold steady before the scrim fades — long enough to span the host
    /// grid-reflow / surface relayout that lands the fresh pixels, short enough not to linger once they
    /// have.
    package static let settle: Duration = .milliseconds(200)

    /// `true` from the moment ``noteSize(_:isDragging:)`` sees a real resize until ``noteSettled()``.
    package private(set) var resizing = false
    /// The last size the settle step observed — distinguishes the initial mount (no scrim) from a real
    /// resize, and lets a continuous drag restart the settle on every step.
    package private(set) var previousSize: CGSize?
    /// STICKY for the duration of an interactive drag: set the first time THIS pane changes size while
    /// a drag is active, cleared when the drag ends.
    package private(set) var resizedDuringDrag = false

    package init() {}

    /// Whether a transition from `previous` to `next` is a RESIZE rather than a mount or a teardown.
    /// Both sides must be real, non-empty sizes and they must differ.
    package static func isResize(from previous: CGSize?, to next: CGSize) -> Bool {
        guard let previous, previous != next else { return false }
        return previous.width > 0 && previous.height > 0 && next.width > 0 && next.height > 0
    }

    /// The pane's laid-out size changed (or was first observed). Arms the scrim for a real resize, and
    /// takes the sticky drag hold when a drag is in flight.
    ///
    /// - Returns: whether the caller should now run the settle wait. `false` means nothing is armed, so
    ///   there is no timer to start.
    @discardableResult
    package mutating func noteSize(_ size: CGSize, isDragging: Bool) -> Bool {
        let previous = previousSize
        previousSize = size
        if Self.isResize(from: previous, to: size) {
            resizing = true
            if isDragging { resizedDuringDrag = true }
        }
        return resizing
    }

    /// The settle wait elapsed with `size` unchanged — drop the geometry signal. The two HOLDS are
    /// untouched: whether the scrim stays up past here is theirs to say.
    package mutating func noteSettled() {
        resizing = false
    }

    /// An interactive drag ended (or was cancelled) — drop the sticky hold. The release commit arms the
    /// model's reflow signal in the same runloop turn, so the two settle together and leave no gap.
    package mutating func noteDragEnded() {
        resizedDuringDrag = false
    }

    /// Whether a drag is currently in flight anywhere. Kept as a parameter rather than stored state:
    /// it is the store's fact about the whole workspace, not this pane's.
    package func isVisible(isDragging: Bool, awaitingReflow: Bool) -> Bool {
        resizing || (isDragging && resizedDuringDrag) || awaitingReflow
    }
}
