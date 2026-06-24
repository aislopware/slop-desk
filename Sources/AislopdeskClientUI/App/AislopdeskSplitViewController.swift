// AislopdeskSplitViewController — the macOS shell (REBUILD-V2, L1). An `NSSplitViewController` with
// three `NSSplitViewItem`s (sidebar | content | inspector), each an `NSHostingController` over a SwiftUI
// column. Modelled on CodeEdit's `CodeEditSplitViewController`: an AppKit split shell with SwiftUI INSIDE
// each column. Keeping the split in AppKit (not a SwiftUI `HSplitView` that rebuilds subtrees) is the
// load-bearing no-teardown choice for L2's libghostty panes — a torn-down NSView kills the surface.
//
// L4a wires the toolbar collapse toggles into the sidebar/inspector `NSSplitViewItem`s (via
// `applyCollapse`) and threads `connection` into the inspector's Session section.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import SwiftUI

final class AislopdeskSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState

    /// Retained so the titlebar toggles can animate their collapse (set in `viewDidLoad`).
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?

    init(store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — AislopdeskSplitViewController is created in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin

        // 1) Sidebar — the navigator (sessions / panes). A PLAIN split item, NOT
        //    `NSSplitViewItem(sidebarWithViewController:)`: the native sidebar style paints system vibrancy +
        //    inset-grouped/rounded selection, which is the "native SwiftUI rounded corners" look we are
        //    replacing. A plain item lets `NavigatorColumn` paint otty's flat warm panel + white-card rows.
        //    Holding priority above the content's default so window-resize grows the content, not the sidebar.
        let navigator = NSHostingController(rootView: NavigatorColumn(store: store))
        let sidebarItem = NSSplitViewItem(viewController: navigator)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // 2) Content — the pane grid (terminal / claude / remote) + otty's hover-reveal titlebar overlay.
        //    The non-collapsible centre. `chrome` drives the titlebar's sidebar/Details toggles.
        let content = NSHostingController(
            rootView: ContentColumn(store: store, connection: connection, chrome: chrome),
        )
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420

        // 3) Inspector — the Session + Commands navigator (host/ping/agent status + the active pane's
        //    command blocks). HIDDEN by default so the resting window is otty's two-column (sidebar | content)
        //    silhouette; revealed from the toolbar (L4a). Matches otty, whose Details panel is hidden until
        //    ⌘⇧R.
        let inspector = NSHostingController(rootView: InspectorColumn(store: store, connection: connection))

        // Each column hosts SwiftUI in its own NSHostingController, which by DEFAULT insets its content below
        // the window's titlebar safe area (the traffic-light strip). With `.hiddenTitleBar` that pushed every
        // column's top chrome — the hover-reveal titlebar's centred title + Details toggle, and the sidebar's
        // "TABS" header — a full row BELOW the traffic lights. Dropping the safe-area regions lets each column
        // start at the window's top edge, so the titlebar's controls land ON the traffic-light row (each
        // column still reserves its own titlebar-height strip at the top).
        navigator.safeAreaRegions = []
        content.safeAreaRegions = []
        inspector.safeAreaRegions = []

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        self.sidebarItem = sidebarItem
        self.inspectorItem = inspectorItem
    }

    /// Pin the WINDOW's appearance to the active otty theme. The three columns are hosted in
    /// `NSHostingController`s inside this AppKit split controller, so they do NOT inherit the SwiftUI
    /// `.preferredColorScheme` set on `WorkspaceRootView` — any system-dynamic colour / material in a column
    /// would otherwise resolve to the OS appearance and clash with the pinned otty palette (e.g. white text
    /// on the light Paper chrome when the user's Mac is in Dark mode). Setting it on the NSWindow propagates
    /// to every hosted NSView. Done in `viewDidAppear` because the window only exists once attached.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.appearance = NSAppearance(named: Otty.theme.isLight ? .aqua : .darkAqua)
    }

    /// Apply the toolbar collapse flags to the sidebar/inspector items (idempotent — only animates a real
    /// change so a steady-state update doesn't re-trigger the animation).
    func applyCollapse(sidebarCollapsed: Bool, inspectorCollapsed: Bool) {
        if let sidebarItem, sidebarItem.isCollapsed != sidebarCollapsed {
            sidebarItem.animator().isCollapsed = sidebarCollapsed
        }
        if let inspectorItem, inspectorItem.isCollapsed != inspectorCollapsed {
            inspectorItem.animator().isCollapsed = inspectorCollapsed
        }
    }
}
#endif
