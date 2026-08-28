// ContentColumnViewController — the trailing column: the pane canvas and the chrome above it.
//
// ⚠️ SKELETON. This file carries the CONTRACT ``WorkspaceRootViewController`` calls (the initializer
// and nothing else) so the shell's containment is real while the canvas itself is rebuilt. The body is
// owned by the canvas cluster; replacing this file wholesale is the intended way to finish it.
//
// The deleted SwiftUI half was `ContentColumn(store:connection:chrome:overlayCoordinator:)` plus the
// `iosToolbar` — the connection pill, the agent glyph, the palette button, the panel menu and `+`.
// The toolbar comes back as this controller's `navigationItem`, because the split gives its secondary
// column a navigation bar for free and the deleted half was fighting `NavigationSplitView` for the
// same space.
//
// ⚠️ THE CANVAS TAKES EVERY KEYSTROKE. The pane surfaces mount through
// ``TerminalRendererFactory``/``VideoWindowFactory``, which hand back a ``PlatformView`` directly now
// — there is no hosting view left to interpose over the surface, which is the whole reason the two
// leaf seams were folded before this file was written.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class ContentColumnViewController: UIViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    private let overlay: OverlayCoordinator

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        overlay: OverlayCoordinator,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.overlay = overlay
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
