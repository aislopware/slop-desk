// ContentColumnViewController — the trailing column: the pane canvas and the chrome above it
// (docs/62 stage E).
//
// The deleted SwiftUI half was `ContentColumn(store:connection:chrome:overlayCoordinator:)` plus the
// `iosToolbar` — the connection pill, the agent glyph, the palette button, the panel menu and `+`. The
// toolbar comes back as this controller's `navigationItem`, because the split gives its secondary
// column a navigation bar for free and the deleted half was fighting `NavigationSplitView` for the same
// space. ⚠️ THAT HALF IS NOT HERE YET: the bar's items belong to the chrome cluster, and this file is
// the canvas cluster's. What is written below is the column's GROUND, its one child, its modal shield
// and its teardown — everything the canvas needs from the column and nothing the toolbar owns.
//
// ⚠️ THE CANVAS TAKES EVERY KEYSTROKE. The pane surfaces mount through
// ``TerminalRendererFactory``/``VideoWindowFactory``, which hand back a ``PlatformView`` directly now —
// there is no hosting view left to interpose over the surface, which is the whole reason the two leaf
// seams were folded before this file was written.
//
// NO ISLAND, NO MOAT, NO RAIL. `MacContentColumn` inlays the canvas in a glass island with a moat, a
// hairline rim and the panel rail beside it; on the phone the canvas IS the column, and
// `slopdesk-invariants`' `ui_seams::canvas-registration` rule pins that by banning the five island
// measurements under `Sources/SlopDeskPhoneUI` outright. The ground here is the chrome's own field
// tone, which shows only in the moment before a canvas exists.
//
// NO DROP-TARGET REGISTRATION EITHER, and that is the same rule's other half: `register(.canvas)` has
// exactly ONE call site in the tree (`MacContentColumn`), because two providers for one key resolve by
// mount order. The phone passes `paneDrag: nil` anyway — there is no satellite window to tear a pane
// out into — so every pane drag here is canvas-local.

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

    private var canvas: PaneCanvasView?
    private var generation = 0

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

        // THE EMPTY STATE'S CONNECT ACTION, RESOLVED HERE. The initializer is frozen — the shell calls
        // it with exactly these four arguments — so no `onConnect` closure arrives, and the deleted
        // SwiftUI column defaulted its own to `{}`: the phone's "Connect" button did NOTHING, which
        // docs/62 §2.1 records as a live defect rather than a design. The Mac routes the same action
        // through `overlay.openConnect()` (`MacWorkspaceRootView.swift:348`), and this controller
        // already holds the coordinator, so the fix is the port rather than a new argument.
        let made = PaneCanvasView(
            // `paneDrag` stays nil — canvas-local drags only, see the file header.
            deps: PaneCanvasDeps(store: store, overlay: overlay, chrome: chrome),
            connection: connection,
            onConnect: { [overlay] in overlay.openConnect() },
        )
        canvas = made
        view.addSubview(made)
        NSLayoutConstraint.activate([
            made.topAnchor.constraint(equalTo: view.topAnchor),
            made.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            made.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            made.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        follow()
    }

    // MARK: - The live read

    /// THE MODAL SHIELD, which is this column's one live read. The deleted half spent
    /// `.allowsHitTesting(!(overlayCoordinator?.anyModalVisible ?? false))` on the same subtree: while a
    /// palette, a cheat sheet, a Connect editor, an Open-Quickly or a peek reply is up, the canvas
    /// underneath must not take a touch. The Mac states it one level further out (`MacModalShield` at
    /// the column root) so it covers the band too; here the navigation bar is the split's, not this
    /// view's, so the flag lands where the deleted half put it.
    ///
    /// Disabling the whole subtree is also what stops a background pane from claiming the keyboard back
    /// out from under a presented card — a touch that never reaches the terminal never re-focuses it.
    private func follow() {
        generation &+= 1
        let generation = generation

        var shielded = false
        withObservationTracking {
            shielded = overlay.anyModalVisible
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        view.isUserInteractionEnabled = !shielded
    }

    /// The column is being taken out of the shell for good. THIS is the canvas's teardown signal, and it
    /// has to be an explicit one: a pane's renderer owns sockets and threads that a mere unmount must
    /// NOT take down (see ``SplitCanvasView``'s reconcile), so nothing below this controller can decide
    /// on its own that a disappearance is final. Leaving the containment is the event that is.
    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        guard parent == nil else { return }
        generation &+= 1
        canvas?.teardown()
    }
}
#endif
