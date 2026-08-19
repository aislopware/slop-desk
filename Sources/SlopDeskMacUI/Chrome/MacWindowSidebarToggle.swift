// MacWindowSidebarToggle — the navigator's show/hide button, in AppKit, and the ONE place it is
// mounted.
//
// It hangs off the WINDOW ROOT (``MacWorkspaceRootView``'s overlay), not off either column. That is
// the whole point: the navigator column and the content column both TRAVEL when the panel collapses
// (the split animates the item's width on ``Slate/Anim/columnSlide``), so a button parked inside
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
// TWO things `MacWorkspaceRootView` still took from that target — the other being the
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
// ⚠️ THE TWO WRAPPERS BELOW ARE A HOSTING SEAM AND NOTHING ELSE — no state, no decision, only the
// PLACE. They exist because ``MacWorkspaceRootView``'s overlay is still SwiftUI; when that mount
// becomes AppKit, ``MacWindowSidebarToggleView`` is handed straight to the window's band and both
// disappear. Same arrangement and same reason as ``RailStatusMarks`` over
// ``MacRailStatusMarksView``, one file over.

import AppKit
import SFSafeSymbols // the glyph name, spelled once and checked by the compiler
import SlopDeskClientCore // WorkspaceChromeState — the ONE collapse flag, owned by the composition
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SwiftUI

/// WHERE the toggle stands — the window-level mount, and the ONE place the button is hosted.
///
/// Pinned to the window's own top-left corner by ``MacWorkspaceRootView``'s `.overlay(alignment:
/// .topLeading)`, INSIDE that root's `.ignoresSafeArea()`. The window is `.hiddenTitleBar` but
/// SwiftUI still hands its content a top safe-area inset the height of the titlebar, so an overlay
/// attached outside the modifier is laid out in the inset content and parks this button one whole
/// band low — on top of the navigator's search field (measured 2026-08-09). The root owns that
/// ordering; this type owns the offsets within it.
struct MacWindowSidebarToggle: View {
    let chrome: WorkspaceChromeState

    var body: some View {
        SidebarTogglePlate(
            collapsed: chrome.sidebarCollapsed,
            // `[chrome]`, so the click flips the SAME `@Observable` the split representable, ⌘⇧L and
            // the palette row drive. One flag, four entry points.
            toggle: { [chrome] in chrome.toggleSidebar() },
        )
        // ⚠️ THE PLATE'S FOOTPRINT, SPELLED ON THE SWIFTUI SIDE. An `NSView` reports
        // `noIntrinsicMetric` on both axes, so an `NSViewRepresentable` with no frame is handed the
        // whole proposal and stretches — ``RailStatusMarks`` pins its cluster for exactly this
        // reason. The number is the plate's own, not a second one.
        .frame(width: Slate.Metric.plate, height: Slate.Metric.plate)
        .padding(.leading, Slate.Metric.windowControlsLead)
        // Hung so its CENTRE lands on the traffic lights' centre — the plate is taller than a light
        // disc, so one shared TOP edge would leave the discs riding high beside it
        // (`SlopDeskMacApp.lowerTrafficLightsToTheTopLine` puts them on that centre).
        .padding(.top, Slate.Metric.bandControlInset)
        .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
    }
}

/// THE HOSTING SEAM. It carries the collapse flag down and the click back up, and it does both in
/// ONE call — the tooltip and the verb are the same button's two halves, and applying them from
/// separate setters leaves a window, one `updateNSView` wide, in which the plate offers to "Show"
/// a panel that is already up.
private struct SidebarTogglePlate: NSViewRepresentable {
    let collapsed: Bool
    let toggle: () -> Void

    func makeNSView(context _: Context) -> MacWindowSidebarToggleView { MacWindowSidebarToggleView() }

    func updateNSView(_ view: MacWindowSidebarToggleView, context _: Context) {
        view.apply(collapsed: collapsed, toggle: toggle)
    }
}

// MARK: - The button, in AppKit

/// The toggle itself: one ``MacPlateIconButton`` and the words that go with it.
///
/// ⚠️ IT IS A CONTAINER AROUND THE PLATE, NOT THE PLATE. ``MacPlateIconButton`` is built for an Auto
/// Layout parent — it clears `translatesAutoresizingMaskIntoConstraints` and constrains its own
/// width and height to ``Slate/Metric/plate`` — and SwiftUI is not one: a representable's root view
/// gets its `frame` assigned directly, which on a view that has opted out of the autoresizing
/// bridge is at best ignored and at worst a constraint conflict. One plain `NSView` in between gives
/// the plate the parent it expects and gives SwiftUI the frame-settable root it expects, and it is
/// the whole reason this class is not just a `typealias`.
@MainActor
final class MacWindowSidebarToggleView: NSView {
    private let plate = MacPlateIconButton(symbolName: SFSymbol.sidebarLeft.rawValue)

    init() {
        super.init(frame: .zero)
        // The plate speaks for this view; the container is scaffolding and must not appear beside it
        // in the accessibility tree as a second, nameless element.
        setAccessibilityElement(false)
        addSubview(plate)
        // Leading + top only. The plate's own constraints already fix its size, so pinning the
        // remaining two edges would state that size a second time — and disagree with it the moment
        // the seam above is handed a frame that is not exactly one plate.
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.topAnchor.constraint(equalTo: topAnchor),
        ])
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
