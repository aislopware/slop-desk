// PhonePanelViewController — the RIGHT panel, as a phone can have one.
//
// ⚠️ SKELETON. This file carries the CONTRACT ``WorkspaceRootViewController`` presents (the
// initializer and ``onClose``) so the presentation is real while the four surfaces are rebuilt. The
// body is owned by the panels cluster.
//
// The Mac hangs its four surfaces — code, simulators, android, desktop — in a third split column and,
// while that column is collapsed, in a RAIL down the window's edge. A phone has room for exactly one
// such thing at a time, so they arrive full-screen (docs/56 stage D), driven by the SAME
// `codeSidebarCollapsed` flag the Mac's split item reads.
//
// ⚠️ EVERY DISMISSAL MUST REACH ``onClose``, including the ones the user performs on the system's
// terms. The flag is the persisted workstyle choice, and a controller torn down without writing it
// back leaves the shell believing the panel is still up — the next toggle then closes an already
// closed panel and the user's tap does nothing.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhonePanelViewController: UIViewController {
    /// Called for every dismissal — the close plate, a swipe, an interactive dismiss. The shell binds
    /// this to `chrome.collapseCodeSidebar()`.
    var onClose: (() -> Void)?

    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    private let overlay: OverlayCoordinator
    private let preferences: PreferencesStore

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        overlay: OverlayCoordinator, preferences: PreferencesStore,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.overlay = overlay
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
    }
}
#endif
