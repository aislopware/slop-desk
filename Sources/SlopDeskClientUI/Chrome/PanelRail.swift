// PanelRail — what the RIGHT panel leaves behind when it collapses (user-directed 2026-08-09).
//
// The panel used to vanish outright, and the only way back was a plate that appeared on hover at the
// window's trailing edge. That plate had nowhere good to stand: with the island rising to the band's
// line, the window's top-right corner belongs to the glass, and a chrome plate parked there either
// straddled the island's 26pt corner (half on cream, half sunk in the glass — unreadable) or had to
// be pushed so far inboard that it no longer read as the panel's own control.
//
// So the panel does not vanish. It narrows to this rail — one plate wide — carrying:
//   • the panel TOGGLE at the top, on the band's control line, at exactly the x the panel's own hide
//     toggle stands at when the panel is open, so the control the user aims at never moves; and
//   • the four surface TABS below it, turned a quarter turn so they run DOWN the rail instead of
//     across the strip. Same tabs, same selection, same plate — only the axis changed, which is the
//     move the horizontal tab strip already makes when the LEFT sidebar collapses.
//
// A rail tab EXPANDS the panel onto its surface. A railed panel shows no surface at all, so a tab
// that only moved the selection would be a control with nothing to show for itself; picking a
// surface is how you ask for it back.

#if os(macOS)
import SFSafeSymbols
import SwiftUI

struct PanelRail: View {
    let chrome: WorkspaceChromeState

    /// The rail's own selection-morph namespace. NOT the panel strip's: only one of the two is ever
    /// mounted, and a plate cannot travel to a tab that does not exist (the same contract the
    /// horizontal tab strip keeps with the sidebar's list).
    @Namespace private var selectionMorph

    var body: some View {
        VStack(spacing: Slate.Metric.space1) {
            PlateIconButton(symbol: .sidebarRight, morphOn: chrome.codeSidebarCollapsed) {
                chrome.toggleCodeSidebar()
            }
            .help("Show the right panel")
            // The toggle hangs from the band's control line like every other control in the band;
            // the tabs start a grid step under it.
            .padding(.top, Slate.Metric.bandControlInset)
            tab(mark: .symbol(.folder), label: "Files", surface: .code)
                .help("Files — the project's embedded editor")
            tab(mark: .symbol(.appleLogo), label: "Simulators", surface: .simulators)
                .help("Simulators — the host's iOS Simulator devices")
            tab(mark: .android, label: "Emulators", surface: .android)
                .help("Emulators — the host's Android emulators and attached devices")
            tab(mark: .symbol(.display), label: "Desktop", surface: .desktop)
                .help("Desktop — the host's window surface")
            Spacer(minLength: 0)
        }
        .frame(width: Slate.Metric.panelRailWidth)
        // The rail is GROUND, like the panel it stands in for — it paints nothing of its own.
        .animation(Slate.Anim.selectionMorph, value: chrome.panelSurface)
    }

    /// One tab, on its side. The plate is built at its ORDINARY size — a fixed length so the four
    /// tabs agree, one control tall — and then rotated a quarter turn; the outer frame is that same
    /// box with its sides swapped, which is what makes the layout believe the rotated result.
    /// Clockwise, so the names read top-to-bottom down the window's trailing edge.
    private func tab(mark: PanelTabPlate.Mark, label: String, surface: PanelSurface) -> some View {
        PanelTabPlate(
            mark: mark, label: label, selected: chrome.panelSurface == surface, spans: true,
            morph: selectionMorph,
        ) {
            chrome.panelSurface = surface
            chrome.revealCodeSidebar()
        }
        .frame(width: Slate.Metric.panelRailTabLength, height: Slate.Metric.heightControl)
        .rotationEffect(.degrees(90))
        .frame(width: Slate.Metric.heightControl, height: Slate.Metric.panelRailTabLength)
    }
}
#endif
