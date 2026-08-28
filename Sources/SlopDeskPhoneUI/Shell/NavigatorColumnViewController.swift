// NavigatorColumnViewController — the leading column: sessions, tabs, panes.
//
// ⚠️ SKELETON. This file carries the CONTRACT ``WorkspaceRootViewController`` calls (the initializer
// and nothing else) so the shell's containment is real while the column itself is rebuilt. The body
// is owned by the navigator cluster; replacing this file wholesale is the intended way to finish it.
//
// The deleted SwiftUI half was `NavigatorColumn(store:)` — a `List` of sessions, each with its tabs
// and panes, plus the sidebar header. The UIKit rebuild is a `UICollectionView` with a list layout
// and a diffable data source: the rows are hierarchical, they reorder under drag, and a `List` with
// `.onMove` was already the shape that made the SwiftUI half's reorder land a frame late.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class NavigatorColumnViewController: UIViewController {
    private let store: WorkspaceStore
    private let chrome: WorkspaceChromeState
    private let overlay: OverlayCoordinator

    init(store: WorkspaceStore, chrome: WorkspaceChromeState, overlay: OverlayCoordinator) {
        self.store = store
        self.chrome = chrome
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The chrome floor, NOT a system sidebar material — the same choice `MacNavigatorColumn` makes
    /// and for the same reason: this is a flat tabs panel on the authored ground, and platform
    /// vibrancy underneath it would tint every ink judged against that ground.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
    }
}
#endif
