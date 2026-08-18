// MacOverlayPanels — which summoned cards are currently WINDOWS, and the one place they are opened
// and closed.
//
// The coordinator's flags stay the single truth: this only diffs them into panels, the way
// ``SatelliteWindowsCoordinator`` diffs `detachedPanes` into satellite windows. Every path runs the
// same direction — a chord, a menu item or a palette row flips the flag, the scene's `.onChange`
// lands here, and the panel follows. A dismissal inside the panel (Esc, Done, a click beside it)
// does NOT tear itself down: it flips the flag back and lets the same edge do it, so the flag and
// the window can never disagree about whether the card is up.
//
// docs/56 stage D drains the macOS surfaces out of `SlopDeskClientUI` one at a time, and this file
// is where each overlay lands as it goes. One so far — the cheat sheet.

import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore

@MainActor
final class MacOverlayPanels {
    /// The live cheat-sheet card, or `nil` when it is not up.
    private var cheatSheet: MacOverlayPanelController?

    /// Reconciles the ⌘/ cheat sheet against `visible`.
    ///
    /// `host` is the workspace window captured in the blessed `.introspect(.window)` closure — with
    /// no window there is nothing to hang a card on, so the call is a silent no-op rather than a
    /// card that opens somewhere the user cannot see.
    func setCheatSheet(
        _ visible: Bool, host: NSWindow?, store: WorkspaceStore, coordinator: OverlayCoordinator,
    ) {
        guard visible else {
            cheatSheet?.dismiss()
            cheatSheet = nil
            // ⚠️ The keyboard has to go back to the PANE. Ordering the panel out restores the
            // workspace window's own first responder, but where the workspace's focus sits is store
            // state rather than responder state — the pane's reclaim paths all gate on a focus
            // TRANSITION or a click, and nothing here changed either. Same call the find bar makes
            // when it closes.
            store.reclaimKeyboardFocusInActivePane()
            return
        }
        guard cheatSheet == nil, let host else { return }
        let controller = MacOverlayPanelController(
            host: host,
            content: MacCheatSheetView(onDone: { [coordinator] in coordinator.closeCheatSheet() }),
            size: MacCheatSheetView.cardSize,
            // Esc and click-away flip the FLAG; the edge that follows closes the panel.
            onDismiss: { [coordinator] in coordinator.closeCheatSheet() },
        )
        cheatSheet = controller
        controller.present()
    }
}
