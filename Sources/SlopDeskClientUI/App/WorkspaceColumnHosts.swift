// WorkspaceColumnHosts — the three hosted columns, handed to the AppKit shell as view controllers.
//
// The macOS split shell (`SlopDeskSplitViewController`, `SlopDeskMacUI`) sits ABOVE this target, so
// it cannot name a SwiftUI column that has not moved yet — and widening whole view structs (and every
// stored property of each) to `package` just to let it call their initializers would publish an API
// that exists only until each column is rewritten in AppKit.
//
// So the seam is factories instead: the shell asks for a column, the draining floor hands back an
// `NSViewController`. Each factory dies with the column it wraps — the NAVIGATOR's already has (that
// column is ``SlopDeskMacUI/MacNavigatorColumn`` now, and all that is left of it here is the one
// SwiftUI island at its foot); when `ContentColumn` becomes AppKit, `content(...)` goes with it and
// the shell instantiates the real thing.
//
// The hosting details that belong to NO column live here too: the overlay-coordinator injection each
// hosted column needs (an `NSHostingController` inherits no WindowGroup environment) and the dropped
// safe-area regions — with `.hiddenTitleBar` the default titlebar inset pushes every column's top
// chrome a full row below the traffic lights.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI

@MainActor
package enum WorkspaceColumnHosts {
    /// The navigator's FOOT — the connection island, hosted for the AppKit column above it.
    ///
    /// The column itself is AppKit now (``SlopDeskMacUI/MacNavigatorColumn``); this one island is not,
    /// and deliberately so: it is drawn in TWO layouts — the column's `stacked` and the titlebar
    /// band's `inline` — and porting one of the two while the strip that mounts the other is still
    /// SwiftUI would create exactly the duplicate implementation `CLAUDE.md` bans. It crosses when the
    /// strip does, and this factory dies with it.
    package static func connectionIsland(
        store: WorkspaceStore, connection: AppConnection, onConnect: @escaping () -> Void,
    ) -> NSView {
        let host = NSHostingView(
            rootView: ConnectionStatusMount(
                store: store, connection: connection, onConnect: onConnect, layout: .stacked,
            )
            // The air the island needs is ABOVE it, not inside it: `space3` separates it from the last
            // project bed by more than the `space2` that separates two projects, so it reads as the
            // column's foot rather than as one more group.
            .padding(.top, Slate.Metric.space3),
        )
        host.safeAreaRegions = []
        return host
    }

    /// The CENTRE column: the pane grid plus the hover-reveal titlebar that overlays it.
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

    /// The RIGHT column: the project-scoped embedded workbench + the device panels beside it.
    package static func codeSidebar(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        preferences: PreferencesStore?,
        overlay: OverlayCoordinator?,
    ) -> NSViewController {
        hosted(
            CodeSidebarColumn(
                store: store, connection: connection, chrome: chrome, preferences: preferences,
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
