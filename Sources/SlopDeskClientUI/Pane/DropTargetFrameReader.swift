// DropTargetFrameReader — the LAST kind 3 in the stage-D ledger, and the only one there ever really
// was (docs/56, "Kind 3 — blocked on a geometry fact, not on effort", and its increment-54 amendment).
//
// It registers the decorated view's SCREEN rect with the drag coordinator, and it cannot be written on
// the AppKit side for a reason that is about GEOMETRY rather than about effort. Increment 41 recorded
// it and every word is still true: the reader is mounted as the background of `SplitContainer`'s
// `GeometryReader`, i.e. against the COMPOSITOR's rect, and the hosting view's frame is not that rect —
// `ContentColumn` applies the island moat and then the panel-rail padding on top of it. An AppKit-side
// registration would be off by the moat, and off by a DIFFERENTLY ANIMATING amount while the sidebar
// collapses, which is exactly the window in which a drag is most likely to be in flight.
//
// WHAT DELETES THIS FILE. Either the canvas is ported whole — `SplitContainer` in AppKit, at which
// point the hosting view's frame IS the canvas and the registration is three lines in the column — or
// the moat leaves SwiftUI first. Both are the same increment in practice: docs/56's step 4, the pane
// canvas. Nothing smaller than that pays for it, which is why this is a file rather than a TODO.
//
// WHY IT IS ALONE HERE. It used to share `PaneDragChrome.swift` with the cursor-following chip panel,
// on the grounds that both were "the drawings the drag needs". They were blocked on different things:
// the chip was blocked on nothing at all — it is a borderless panel over a card, which AppKit draws
// natively — and it crossed in increment 56e as `MacPaneDragChipPanel`. Increment 54's own lesson
// applies to the file as much as it did to the coordinator: "blocked on a geometry fact" was a property
// of ONE declaration, and it was allowed to describe its neighbours because the file was the unit. One
// declaration, one file, so the next reader cannot inherit the wrong verdict by proximity.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)

/// Registers the decorated view's SCREEN frame with the drag coordinator under `key` — resolved lazily
/// through a weak `NSView` handle, so scrolling / layout never publishes anything. Mount it in a
/// `.background` (the view is hit-test transparent). The `.canvas` key doubles as the main-window
/// frame source (the tear-off boundary).
struct DropTargetFrameReader: NSViewRepresentable {
    let key: PaneDropTargetKey
    let coordinator: PaneDragCoordinator

    final class Coordinator {
        var registeredKey: PaneDropTargetKey?
        weak var drag: PaneDragCoordinator?
    }

    /// An `NSView` that never claims a hit — the reader must not shadow the SwiftUI content it backs.
    final class PassthroughView: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        register(view, context: context)
        return view
    }

    func updateNSView(_ view: PassthroughView, context: Context) {
        // A reused row view can be re-keyed (LazyVStack recycling) — move the registration.
        guard context.coordinator.registeredKey != key else { return }
        if let old = context.coordinator.registeredKey { coordinator.unregister(old) }
        register(view, context: context)
    }

    static func dismantleNSView(_: PassthroughView, coordinator: Coordinator) {
        if let key = coordinator.registeredKey { coordinator.drag?.unregister(key) }
    }

    private func register(_ view: PassthroughView, context: Context) {
        context.coordinator.registeredKey = key
        context.coordinator.drag = coordinator
        coordinator.register(key) { [weak view] in
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        if key == .canvas {
            coordinator.mainWindowFrame = { [weak view] in view?.window?.frame }
        }
    }
}
#endif
#endif
