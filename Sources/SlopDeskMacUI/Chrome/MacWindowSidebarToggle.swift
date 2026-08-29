// MacWindowSidebarToggle — the navigator's show/hide button, in AppKit, and the ONE place it is
// mounted.
//
// It hangs off the WINDOW ROOT (``MacWorkspaceWindowController``'s content view), not off either
// column. That is the whole point: the navigator column and the content column both TRAVEL when the
// panel collapses (the split animates the item's width on ``Slate/Motion/columnSlide``), so a button parked inside
// either one rides that slide — it crawled out from under the traffic lights on its way across,
// which is the motion the user reported 2026-08-09. The button does not belong to a column; it
// belongs to the window's top-left corner, beside the lights, at
// ``Slate/Metric/windowControlsLead``. Mounted there it is geometrically INCAPABLE of moving, in
// either direction, at any duration.
//
// It replaced a PAIR of buttons that only pretended to be one: a hide twin inside the navigator's
// own strip and a reveal twin in the titlebar, cross-faded at the same x. Two views, two opacity
// choreographies, one apparent control — and any drift between them read as the button flickering.
//
// WHY IT IS HERE AND NOT ON THE DRAINING FLOOR (docs/56 §3.5, increment 56b). It was
// `WindowSidebarToggle`, a `package` SwiftUI view in `SlopDeskClientUI`, and it was one of exactly
// TWO things the Mac's window root still took from that target — the other being the
// `\.preferencesStore` environment key, which is an init parameter now. The phone never drew it and
// could not: it has no window corner, no traffic lights and no split item to collapse. So it was a
// macOS-only control sitting on the shared floor, which is the arrangement stage D exists to end,
// and the file that held it is DELETED in this change rather than gated or kept as a fallback (one
// implementation, never two languages — `CLAUDE.md`).
//
// ⚠️ THE GLYPH BOUNCE IS GONE, and that is a ruling this file inherits rather than makes. The
// SwiftUI original handed `PlateIconButton` a `morphOn:` and got `symbolEffect(.bounce.down)` on the
// flag the click lands on. `symbolEffect` has no AppKit equivalent that does not amount to
// reimplementing it, which is exactly what ``MacPlateIconButton``'s header already decided for every
// other plate in this target — so the Mac's plate spends the FILL rung alone, which was always the
// load-bearing half (the bounce answers "a click arrived", the rung answers "and here is where it
// lands"). One acknowledgement idiom for every plate in the window beats one plate that keeps a
// second one alive for itself.
//
// ⚠️ IT DOES NOT LATCH, at either end of the toggle. The SwiftUI original never passed `active:`
// and this one does not either: a latched plate means "the thing I turn on is on", and what this
// button turns on is a COLUMN that is either visibly there or visibly not. A permanently half-lit
// plate beside the traffic lights would restate, in the faintest channel the chrome has, the one
// fact the window is already shouting. What changes across the flip is the TOOLTIP — the only place
// the direction of the verb has to be said, and the only place a pointer will ask.
//
// ⚠️ THE TWO WRAPPERS THAT USED TO STAND HERE ARE GONE, AND THEY WERE ONLY EVER A HOSTING SEAM — no
// state, no decision, only the PLACE. `MacWindowSidebarToggle` (a `View`) and `SidebarTogglePlate`
// (an `NSViewRepresentable`) existed because the Mac root's overlay was SwiftUI; that
// root is a window CONTROLLER now, so the view below is handed straight to the window's content and
// both wrappers are deleted rather than ported. Their geometry came with them: ``leadingInset`` and
// ``topInset`` below are the `.padding(.leading, …)` / `.padding(.top, …)` they carried, spelled
// once here so the window controller's constraints and this view agree by construction.
//
// Two of the SwiftUI numbers did NOT survive, because what they were correcting for is gone:
//   * `.frame(width: plate, height: plate)` was there because an `NSView` reports `noIntrinsicMetric`
//     on both axes, so a representable with no frame is handed the whole proposal and stretches. Auto
//     Layout does not propose: the plate's own width/height constraints (``MacPlateIconButton``) are
//     what size this container, and stating them again would be a second source for one number.
//   * `.frame(height: titlebarHeight, alignment: .top)` was there because a SwiftUI overlay is laid
//     out against its parent's whole height and had to be pushed back up to the band. A constraint to
//     the content view's `topAnchor` says that directly.

import AppKit
import SFSafeSymbols // the glyph name, spelled once and checked by the compiler
import SlopDeskClientCore // WorkspaceChromeState — the ONE collapse flag, owned by the composition
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

// MARK: - The button, in AppKit

/// The toggle itself: one ``MacPlateIconButton`` and the words that go with it.
///
/// ⚠️ IT IS A CONTAINER AROUND THE PLATE, NOT THE PLATE. ``MacPlateIconButton`` is built for an Auto
/// Layout parent — it clears `translatesAutoresizingMaskIntoConstraints` and constrains its own width
/// and height to ``Slate/Metric/plate``. The container was originally what gave SwiftUI a
/// frame-settable root while giving the plate the Auto Layout parent it expects; with the
/// representable gone the second half is the whole reason, and it still stands: the window controller
/// pins THIS view's leading and top edges to the window's corner and the plate is pinned to all four
/// of THIS view's edges, so the plate's own size constraint is the single number that decides how big
/// either view is — neither side restates it.
@MainActor
final class MacWindowSidebarToggleView: NSView {
    /// The distance from the window's leading edge — the traffic lights' own lane
    /// (``Slate/Metric/windowControlsLead``), so the plate stands immediately after them rather than
    /// at a second inset that would have to be kept in step with theirs.
    static let leadingInset = Slate.Metric.windowControlsLead

    /// Hung so the plate's CENTRE lands on the traffic lights' centre — the plate is taller than a
    /// light disc, so one shared TOP edge would leave the discs riding high beside it
    /// (``SlopDeskMacApp/lowerTrafficLightsToTheTopLine(on:)`` puts them on that centre).
    static let topInset = Slate.Metric.bandControlInset

    private let plate = MacPlateIconButton(symbolName: SFSymbol.sidebarLeft.rawValue)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The plate speaks for this view; the container is scaffolding and must not appear beside it
        // in the accessibility tree as a second, nameless element.
        setAccessibilityElement(false)
        addSubview(plate)
        // ALL FOUR EDGES, and the missing two are the difference between a live button and a drawn
        // one. The plate's own width/height constraints are still the only place its size is stated —
        // pinning trailing and bottom does not restate it, it PROPAGATES it, which is the only way an
        // Auto Layout container with no `intrinsicContentSize` of its own ever gets a size. With
        // leading + top alone this view is 0×0: the plate draws fine (nothing clips it) but
        // `hitTest(_:)` walks by FRAME, so every click on the glyph falls through to the split
        // beneath and the toggle is dead. The old comment here argued against the other two edges
        // because the representable above might hand down a frame that was not exactly one plate;
        // that seam is deleted, so there is no other frame to disagree with.
        NSLayoutConstraint.activate(plate.slateEdges(of: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Apply the live collapse flag and the verb.
    ///
    /// The words name the PANEL, not the button — "Show/Hide the tabs panel", the same noun the
    /// palette row and the ⌘⇧L cheat-sheet entry use, so the three surfaces that drive this one flag
    /// cannot be read as three different features. They land on the tooltip AND the accessibility
    /// label together: a plate is a glyph and nothing else, so a reader with no pointer has no other
    /// way to learn which way the verb points.
    func apply(collapsed: Bool, toggle: @escaping () -> Void) {
        plate.onClick = toggle
        let help = collapsed ? "Show the tabs panel" : "Hide the tabs panel"
        plate.toolTip = help
        plate.setAccessibilityLabel(help)
    }
}
