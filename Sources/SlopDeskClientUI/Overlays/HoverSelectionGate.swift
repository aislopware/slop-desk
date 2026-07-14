// HoverSelectionGate — the shared hover→keyboard-selection arbiter for the palette-family lists
// (PaletteView / OpenQuicklyView / CommandNavigatorView: hover moves the selection, selection change
// auto-scrolls the selected row to center). Naive wiring of those two behaviors creates TWO feedback loops:
//
// 1. **The list follows the mouse.** Hover selects the row under the pointer → `scrollTo(.center)` slides
//    that row to the middle → a NEW row arrives under the (still-moving) pointer → hover selects it → the
//    list scrolls again, continuously, as long as the mouse moves inside the viewport. Fix: a HOVER-driven
//    selection change must never auto-scroll — only keyboard nav (and the query-edit reset) may.
// 2. **Keyboard nav gets yanked back to the mouse row.** A keyboard `scrollTo` slides a new row under a
//    STATIONARY pointer; AppKit re-fires hover for it (tracking areas update on scroll), which would snap
//    the selection straight back to whatever sits under the parked mouse. Fix: admit a hover event only
//    when the pointer's GLOBAL location actually changed since the last one — the list moving under a
//    parked pointer is not a hover intent.
//
// One instance per LIST (`@State` on the overlay view, so it resets per presentation), shared across its
// rows — a per-row store would make scroll-induced entry into a never-hovered row look like movement.
//
// A plain (non-`@Observable`) reference type on purpose: it mutates on every pointer move, and none of its
// state is render input — observation would re-render the overlay per pixel of mouse travel.

#if canImport(SwiftUI)
import CoreGraphics

@MainActor
final class HoverSelectionGate {
    /// The pointer's global-space location at the last hover event (admitted or not). `nil` until the first
    /// event of this presentation — which is therefore always admitted (matching the pre-gate behavior of
    /// a fresh open under the pointer).
    private var lastPointerLocation: CGPoint?

    /// Set between a hover-driven selection write and the list's `onChange(selection)` observer — the
    /// check-and-clear window that suppresses exactly that one auto-scroll.
    private var selectionIsHoverDriven = false

    /// Whether this hover event is genuine pointer MOVEMENT (vs the list scrolling under a parked pointer,
    /// which re-fires hover at an unchanged global location). Call with the `.global`-space location of
    /// every `.active` hover phase; only a `true` return may move the selection.
    func admitHover(at location: CGPoint) -> Bool {
        defer { lastPointerLocation = location }
        return location != lastPointerLocation
    }

    /// Mark the selection write that immediately follows as hover-driven. Call ONLY when the write is a
    /// real change (guard `selection != index` first) — an unchanged selection never fires `onChange`, and
    /// a stale mark would then swallow the next keyboard scroll.
    func noteHoverDrivenSelection() { selectionIsHoverDriven = true }

    /// Whether the selection change being observed should auto-scroll the selected row into view —
    /// `false` exactly once after ``noteHoverDrivenSelection()`` (check-and-clear), `true` for keyboard
    /// nav and programmatic resets.
    func shouldAutoScrollOnSelectionChange() -> Bool {
        defer { selectionIsHoverDriven = false }
        return !selectionIsHoverDriven
    }
}
#endif
