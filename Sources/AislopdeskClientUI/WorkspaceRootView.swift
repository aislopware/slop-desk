// WorkspaceRootView — the native 3-column IDE shell (REBUILD-V2, L1).
//
// macOS: an `NSViewControllerRepresentable` (`WorkspaceSplitRepresentable`) owning an
// `AislopdeskSplitViewController` (an `NSSplitViewController` with sidebar | content | inspector items,
// each an `NSHostingController` over a SwiftUI column). Modelled on CodeEdit's split shell.
// iOS: a stock `NavigationSplitView` over the same three placeholder columns.
//
// NO custom design-system / token target (deleted in L0): SYSTEM semantic colours + fonts only. The
// real navigator rows / pane grid / terminal surface land in L2 — these columns are placeholders.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

public struct WorkspaceRootView: View {
    let store: WorkspaceStore
    let connection: AppConnection

    public init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
    }

    public var body: some View {
        #if os(macOS)
        WorkspaceSplitRepresentable(store: store, connection: connection)
            .ignoresSafeArea()
        #else
        NavigationSplitView {
            NavigatorColumn(store: store)
        } content: {
            ContentColumn(store: store, connection: connection)
        } detail: {
            InspectorColumn(store: store)
        }
        #endif
    }
}

#if os(macOS)
/// Bridges the AppKit `AislopdeskSplitViewController` into SwiftUI. The controller (and the three
/// SwiftUI columns it hosts) owns the long-lived shell; SwiftUI just mounts it. Keeping the shell in
/// AppKit (not a SwiftUI `HSplitView`) is the load-bearing no-teardown choice for L2's libghostty panes.
struct WorkspaceSplitRepresentable: NSViewControllerRepresentable {
    let store: WorkspaceStore
    let connection: AppConnection

    func makeNSViewController(context _: Context) -> AislopdeskSplitViewController {
        AislopdeskSplitViewController(store: store, connection: connection)
    }

    func updateNSViewController(_: AislopdeskSplitViewController, context _: Context) {
        // L1 columns are static placeholders; nothing to push per-update yet (L2 wires live state).
    }
}
#endif
#endif
