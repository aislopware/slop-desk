// WorkspaceColumnHosts — the three hosted columns, handed to the AppKit shell as view controllers.
//
// The macOS split shell (`SlopDeskSplitViewController`, `SlopDeskMacUI`) sits ABOVE this target, so
// it cannot name a SwiftUI column that has not moved yet — and widening whole view structs (and every
// stored property of each) to `package` just to let it call their initializers would publish an API
// that exists only until each column is rewritten in AppKit.
//
// So the seam is factories instead: the shell asks for a column, the draining floor hands back an
// `NSViewController`. Each factory dies with the column it wraps — the NAVIGATOR's already has (that
// column is ``SlopDeskMacUI/MacNavigatorColumn`` now, foot and all), and `content(...)` is down to the
// pane CANVAS ALONE: the titlebar band over it (``SlopDeskMacUI/MacTitlebarBand``), the rail beside it
// and, since stage F's P5, the ISLAND UNDER IT are all AppKit, and this hosted view is the island's
// whole interior (``SlopDeskMacUI/MacContentColumn``). This factory dies when `SplitContainer` crosses.
//
// The RIGHT column's factory is GONE, and it went in two steps rather than one, which is the shape a
// big surface crosses in. Increment 51 rewrote the four surfaces, the five poll loops, the collapse
// fade and the reports in AppKit and NARROWED the factory to the two device surfaces; increment 52
// rewrote those and the factory had nothing left to hand over. A seam that narrows before it closes
// is the honest signal that the thing behind it was bigger than the ledger said.
//
// The hosting details that belong to NO column live here too: the overlay-coordinator injection each
// hosted column needs (an `NSHostingController` inherits no WindowGroup environment) and the dropped
// safe-area regions — with `.hiddenTitleBar` the default titlebar inset pushes every column's top
// chrome a full row below the traffic lights.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskWorkspaceCore
import SwiftUI

@MainActor
package enum WorkspaceColumnHosts {
    /// The CENTRE column's CANVAS — the pane grid and nothing around it. The island it stands on, the
    /// titlebar band over it and the collapsed panel's rail beside it are all AppKit, and this view is
    /// mounted INSIDE the island as its whole interior (``SlopDeskMacUI/MacContentColumn``).
    ///
    /// Hence `ground: nil`: the island's layer is what this canvas stands on, so painting a ground
    /// here would lay chrome cream over the glass. It is also what makes the hosting view's frame the
    /// canvas's rect exactly, which is why the pane drag's `.canvas` registration is three lines up
    /// there instead of a SwiftUI reader down here (docs/56 stage F, P5).
    package static func content(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        onConnect: @escaping () -> Void,
        paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator?,
    ) -> NSViewController {
        hosted(
            ContentColumn(
                store: store, connection: connection, chrome: chrome, onConnect: onConnect,
                paneDrag: paneDrag, ground: nil,
            ),
            overlay: overlay,
        )
    }

    /// Mount one column: inject the reducer the hosted tree cannot inherit, and drop the titlebar
    /// safe-area inset so the column starts at the window's own top edge.
    private static func hosted(_ column: some View, overlay: OverlayCoordinator?) -> NSViewController {
        let controller = NSHostingController(rootView: column.overlayCoordinator(overlay))
        controller.safeAreaRegions = []
        return controller
    }
}
#endif
