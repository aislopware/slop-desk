// AislopdeskSplitViewController — the macOS shell (REBUILD-V2, L1). An `NSSplitViewController` with
// three `NSSplitViewItem`s (sidebar | content | inspector), each an `NSHostingController` over a SwiftUI
// column. Modelled on CodeEdit's `CodeEditSplitViewController`: an AppKit split shell with SwiftUI INSIDE
// each column. Keeping the split in AppKit (not a SwiftUI `HSplitView` that rebuilds subtrees) is the
// load-bearing no-teardown choice for L2's libghostty panes — a torn-down NSView kills the surface.
//
// L1 hosts PLACEHOLDER columns; the real navigator/pane-grid/inspector content lands in L2/L4.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import SwiftUI

final class AislopdeskSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection

    init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — AislopdeskSplitViewController is created in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin

        // 1) Sidebar — the navigator (sessions / panes). Collapsible, spring-loaded so a drag over the
        //    collapsed edge reveals it. Width clamped to a sidebar-typical range.
        let navigator = NSHostingController(rootView: NavigatorColumn(store: store))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isSpringLoaded = true

        // 2) Content — the pane grid (terminal / claude / remote). The non-collapsible centre.
        let content = NSHostingController(rootView: ContentColumn(store: store, connection: connection))
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420

        // 3) Inspector — agent status / branch / host / ping / tokens / exit codes. Hidden by default.
        let inspector = NSHostingController(rootView: InspectorColumn(store: store))
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }
}
#endif
