// WindowSidebarToggle — the navigator's show/hide button, and the ONE place it is mounted.
//
// It hangs off the WINDOW ROOT (`WorkspaceRootView`'s macOS overlay), not off either column. That is
// the whole point: the navigator column and the content column both TRAVEL when the panel collapses
// (the split animates the item's width on ``Slate/Anim/columnSlide``), so a button parked inside
// either one rides that slide — it crawled out from under the traffic lights on its way across, which
// is the motion the user reported 2026-08-09. The button does not belong to a column; it belongs to
// the window's top-left corner, beside the lights, at ``Slate/Metric/windowControlsLead``. Mounted
// there it is geometrically INCAPABLE of moving, in either direction, at any duration.
//
// This replaced a PAIR of buttons that only pretended to be one: a hide twin inside the navigator's
// own strip and a reveal twin in the titlebar, cross-faded at the same x. Two views, two opacity
// choreographies, one apparent control — and any drift between them read as the button flickering.
//
// The click's whole acknowledgement is the button itself: the plate fills under the press
// (``SlatePlateStyle``) and the glyph takes a short bounce when the flag actually flips. A press
// morph rather than a journey — the control is a fixed landmark, and what changed is the panel, not
// the button (user-directed 2026-08-09).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

struct WindowSidebarToggle: View {
    let chrome: WorkspaceChromeState

    var body: some View {
        PlateIconButton(
            symbol: .sidebarLeft,
            // The glyph squashes on the state the click lands on — including a ⌘⇧L, a palette row or
            // the auto-hide policy, because the morph belongs to the FLAG, not to the pointer.
            morphOn: chrome.sidebarCollapsed,
        ) { chrome.toggleSidebar() }
            .help(chrome.sidebarCollapsed ? "Show the tabs panel" : "Hide the tabs panel")
            .padding(.leading, Slate.Metric.windowControlsLead)
            // Centre in the band, which is where AppKit now centres the traffic lights too
            // (`SlopDeskClientApp.growTitlebarToBandHeight`) — one row across the whole strip.
            .frame(height: Slate.Metric.titlebarHeight)
    }
}
#endif
