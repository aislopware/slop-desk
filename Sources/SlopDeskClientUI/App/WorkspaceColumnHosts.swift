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
// pane CANVAS: the titlebar band over it is AppKit (``SlopDeskMacUI/MacTitlebarBand``) and the two are
// siblings under ``SlopDeskMacUI/MacContentColumn``. This factory dies when `SplitContainer` crosses.
//
// The RIGHT column's factory NARROWED rather than dying, which is the shape a big surface crosses in.
// It used to hand over the whole column; increment 51 rewrote the four surfaces, the five poll loops,
// the collapse fade and the reports in AppKit, and what is left crossing is the two device SURFACES —
// still SwiftUI, and the next thing to go.
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
    /// The CENTRE column's CANVAS: the pane grid, its island geometry and the collapsed panel's rail.
    /// The titlebar band that stands over it is AppKit and is mounted as this view's SIBLING — see
    /// ``SlopDeskMacUI/MacContentColumn``.
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
                paneDrag: paneDrag,
            ),
            overlay: overlay,
        )
    }

    /// The Simulators surface's two depths — the device list and the live stage.
    ///
    /// A far narrower seam than the `codePanelSurfaces(...)` it replaced in increment 51. That factory
    /// handed over the whole right column: four surfaces, five poll loops, the collapse fade and the
    /// reports. All of that is ``SlopDeskMacUI/MacCodePanelSurfaces`` now, and what still crosses is the
    /// ~4,100 lines of device-panel SwiftUI that have not been rewritten yet — so the factory names the
    /// two surfaces themselves rather than the column that used to contain them.
    package static func simulatorSurface(
        model: SimulatorSidebarModel, overlay: OverlayCoordinator?,
    ) -> NSViewController {
        hosted(SimulatorSurface(model: model), overlay: overlay)
    }

    /// The Android surface's two depths. A FOURTH tab rather than a second half of Simulators: the two
    /// share not one byte of protocol, and folding them into one surface would mean a list whose rows
    /// dispatch on platform and a stage whose every control has two implementations.
    package static func androidSurface(
        model: AndroidSidebarModel, overlay: OverlayCoordinator?,
    ) -> NSViewController {
        hosted(AndroidSurface(model: model), overlay: overlay)
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
