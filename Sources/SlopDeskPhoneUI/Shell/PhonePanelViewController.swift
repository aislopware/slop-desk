// PhonePanelViewController — the RIGHT panel, as a phone can have one.
//
// The Mac hangs its four surfaces — code, simulators, android, desktop — in a third split column and,
// while that column is collapsed, in a RAIL down the window's edge. A phone has room for exactly one
// such thing at a time, so they arrive full-screen (docs/56 stage D), driven by the SAME
// `codeSidebarCollapsed` flag the Mac's split item reads.
//
// Two SIBLINGS under this controller, not a stack of one inside the other — the shape
// ``SlopDeskMacUI/MacCodePanelColumn`` takes, for the same reason:
//   1. ``PhonePanelBar`` — the panel's own top bar: the four surface tabs, the showing surface's reload
//      plate, and the close plate at the far trailing corner.
//   2. the four SURFACES — ``PhonePanelSurfacesViewController`` — pinned under it.
//
// What each surface SAYS is `SlopDeskClientCore`'s (``CodePanelPresentation``), because the Mac hangs
// its own chrome — a strip and a rail, not a bar — off the same three models and the same words.
//
// ## ⚠️ EVERY DISMISSAL MUST REACH ``onClose``
//
// The flag is the persisted workstyle choice, and a controller torn down without writing it back leaves
// the shell believing the panel is still up — the next toggle then closes an already closed panel and
// the user's tap does nothing. There are three ways this controller can leave the screen and each is
// answered below at ``reportClose()``: the close plate, a system dismissal (the swipe, an interactive
// gesture), and a programmatic `dismiss` the shell issues after the flag has already been written. The
// latch makes the report EXACTLY ONCE, and `collapseCodeSidebar()` is itself guarded, so the third path
// costs nothing when it is the shell's own actuation arriving back here.
//
// ## The three models are NOT owned by this controller, and that is load-bearing
//
// A presentation is minted on every open and released on every close. Models held here would re-list
// every device and re-boot every stream each time the panel came up, and the parking rules
// (``SimulatorSidebarModel/park()``) already assume something outlives the surface tree. The Mac keeps
// them on its column, which is built once and only ever faded; the phone has no such object, so they
// are ``PhonePanelModels/shared`` — process-lifetime, which is the lifetime the parking rules were
// written against. The deleted SwiftUI reached the same answer by hanging them off the root view.
//
// ## ⚠️ THE PANEL HAS NO NOTIFICATION CORNER YET, and it is owed one
//
// The surfaces under this bar SPEAK — a simulator boot that failed, a capture that landed on the
// clipboard — through the same coordinator the workspace's stack reads, and that stack is mounted on
// the shell's root, which this presentation covers. Until the overlays cluster lands a card layer that
// a presented controller can mount, every report the panel makes while it is up is filed behind the
// thing that filed it. The deleted `PhonePanelSheet` solved it with a second `ToastStackView` in an
// `.overlay`; the UIKit answer is the same shape and belongs here, over ``surfaces``. The palette
// deliberately does NOT follow: a phone shows one place at a time, and the panel's own bar is its
// command surface.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

/// The three surface models, held for the process rather than for a presentation.
///
/// A class rather than three globals so the lifetime is stated once, in one place, with the reason
/// beside it: a panel that is dismissed and re-opened must not re-list every device and re-boot every
/// stream, and ``SimulatorSidebarModel/park()`` / ``SimulatorSidebarModel/resume()`` are written on the
/// assumption that something outlives the surface tree.
@MainActor
final class PhonePanelModels {
    static let shared = PhonePanelModels()

    let code = CodeSidebarModel()
    let simulator = SimulatorSidebarModel()
    /// A FOURTH tab rather than a second half of Simulators: the two share not one byte of protocol —
    /// `baguette`'s websocket against `scrcpy` over `adb`, AVC against Annex-B, JSON envelopes against
    /// packed control messages — and folding them into one surface would mean a list whose rows dispatch
    /// on platform and a stage whose every control has two implementations. They are two device sets
    /// that happen to look alike in a sidebar. The reasoning is the Mac column's and it is recorded
    /// there too.
    let android = AndroidSidebarModel()

    private init() {}
}

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

    private let models = PhonePanelModels.shared
    private let bar: PhonePanelBar
    private let surfaces: PhonePanelSurfacesViewController

    /// Whether ``onClose`` has already been called for this presentation. The three dismissal paths can
    /// overlap — the close plate's own `dismiss` reaches `viewDidDisappear` too — and the flag is a
    /// persisted workstyle choice rather than a toggle, so reporting twice is not obviously harmless
    /// enough to rely on.
    private var reportedClose = false

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        overlay: OverlayCoordinator, preferences: PreferencesStore,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.overlay = overlay
        self.preferences = preferences
        // Two boxes the bar's stored verbs close over, filled in after `super.init`. The bar is built
        // before `self` exists — Swift's phase 1 — and `PhonePanelModels.shared` is named rather than
        // read through the stored property for the same reason: no storage on `self` is readable yet.
        let reload = ClosureBox()
        let close = ClosureBox()
        bar = PhonePanelBar(
            chrome: chrome, onReload: { reload.run?() }, onClose: { close.run?() },
        )
        let models = PhonePanelModels.shared
        surfaces = PhonePanelSurfacesViewController(
            store: store, connection: connection, chrome: chrome, preferences: preferences,
            overlay: overlay, model: models.code, simulatorModel: models.simulator,
            androidModel: models.android,
        )
        super.init(nibName: nil, bundle: nil)
        // Weak, so a plate's stored verb cannot keep a dismissed panel alive (docs/62 hazard 1).
        reload.run = { [weak self] in self?.reloadShowingSurface() }
        close.run = { [weak self] in self?.closeFromPlate() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: - Mounting

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
        // ⚠️ HERE, NOT IN `init`. `presentationController` is `nil` until a presentation style has been
        // chosen and a presenter has been named, and the shell does both AFTER `init` returns — an
        // assignment there would land on nothing and the swipe would go unreported, which is precisely
        // the dismissal this file exists to catch.
        presentationController?.delegate = self

        mountBar()
        mountSurfaces()
        followReloadable()
    }

    /// The bar hangs from the SAFE AREA, not the top edge. A full-screen presentation covers the status
    /// bar and the notch, and a row of tab plates drawn under either is a row the reader cannot reach.
    private func mountBar() {
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// The surfaces take the whole rest of the screen INCLUDING the home indicator's band — a device
    /// stage fitted to the safe area draws a cream stripe under the mirror, which reads as the panel
    /// having failed to fill the screen rather than as a system inset.
    private func mountSurfaces() {
        addChild(surfaces)
        surfaces.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surfaces.view)
        NSLayoutConstraint.activate([
            surfaces.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            surfaces.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaces.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaces.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        surfaces.didMove(toParent: self)
    }

    // MARK: - The bar's one action

    /// What the bar's reload plate does on the surface currently showing. Resolved HERE and not in the
    /// bar, because what "reload" means is the SURFACE's business and the bar only carries the verb —
    /// the Mac's column wires the same four answers from its own strip, for the same reason.
    private func reloadShowingSurface() {
        switch chrome.panelSurface {
        case .code:
            guard let root = activeProjectRoot else { return }
            CodeSidebarWebViewPool.shared.reload(projectRoot: root)
            models.code.requestReload()
        case .simulators:
            models.simulator.requestReload()
        case .android:
            models.android.requestReload()
        case .desktop:
            break
        }
    }

    /// Whether the workbench is MOUNTED — behind the open gate there is nothing to reload, and a bump of
    /// the poll generation would boot the very thing the gate exists to defer.
    private func followReloadable() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        var reloadable = false
        withObservationTracking {
            reloadable = activeProjectRoot.map(chrome.openedCodeProjects.contains) ?? false
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.reloadGeneration else { return }
                    self.followReloadable()
                }
            }
        }
        bar.codeReloadable = reloadable
    }

    /// Supersedes a callback armed before ``teardown()``. The store and the chrome state are
    /// app-lifetime, so a dismissed panel would keep re-arming on them forever (docs/62 hazard 2).
    private var reloadGeneration = 0

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the cwd
    /// fallback the sidebar sections tolerate. Ensuring on the transient pre-push cwd spawns a
    /// code-server for a root the project does not have.
    private var activeProjectRoot: String? {
        guard let pane = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    // MARK: - Leaving

    /// The close PLATE, which does not dismiss anything.
    ///
    /// It writes the flag and stops. The shell owns every presentation and dismissal on this platform —
    /// it observes `codeSidebarCollapsed` and takes the panel down itself — so dismissing here as well
    /// would be a second dismissal racing the shell's own, which UIKit drops silently. Writing the flag
    /// makes the plate indistinguishable from ⌘⇧R and from the palette's View row, which is the point.
    private func closeFromPlate() {
        reportClose()
    }

    /// Write the workstyle choice back, exactly once.
    ///
    /// ⚠️ THE LATCH IS WHAT MAKES THE THREE PATHS SAFE TO OVERLAP. The close plate reports here; a
    /// system dismissal reports here through ``presentationControllerDidDismiss(_:)``; and
    /// ``viewDidDisappear(_:)`` reports here for every other way this controller can leave, including
    /// the one the shell drives after the flag has already been written. Without the latch that last
    /// path would re-enter a close that is already finished.
    private func reportClose() {
        guard !reportedClose else { return }
        reportedClose = true
        onClose?()
    }

    /// A SYSTEM dismissal — the swipe down, an interactive gesture, anything the reader performs on the
    /// platform's terms rather than on the panel's. A programmatic `dismiss(animated:)` does NOT call
    /// this, which is exactly the distinction that keeps the shell's own actuation from re-entering.
    ///
    /// It fires AFTER the controller is off screen, so there is nothing left to tear down here beyond
    /// the flag — ``viewDidDisappear(_:)`` has already stopped the loops.
    private func systemDidDismiss() {
        reportClose()
    }

    /// Every departure that is really a DISMISSAL, and no other.
    ///
    /// ⚠️ `isBeingDismissed` IS THE WHOLE GUARD, and `parent == nil` is not a second half of it — a
    /// PRESENTED controller always has a `nil` parent, because `parent` is containment and this is
    /// presentation, so an `||` with it is a guard that never refuses anything. What it would then let
    /// through is every disappearance the panel causes ITSELF: the simulator's location popover adapts
    /// to a sheet in compact width, and a full-screen sheet over this panel fires this method with
    /// nothing being dismissed. The panel would park both streams, cancel five loops and write the
    /// workstyle flag — closing itself under a sheet the reader just opened.
    ///
    /// ``teardown()`` before the report, and that order matters: parking a device stream releases a host
    /// encoder and two websockets, and the shell may mint a new panel the moment the flag settles.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        teardown()
        reportClose()
    }

    /// Stop every loop and every observation this panel armed.
    ///
    /// Explicit rather than left to `deinit`: a `Task` holding its model weakly still holds a socket
    /// open, and a tracker armed on an app-lifetime model keeps this controller alive to service it.
    private func teardown() {
        reloadGeneration &+= 1
        bar.teardown()
        surfaces.teardown()
    }
}

// MARK: - The system's own edges

extension PhonePanelViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_: UIPresentationController) {
        systemDidDismiss()
    }
}

/// A settable slot a phase-1 initializer can hand out and a phase-2 one can fill.
///
/// Swift's two-phase init makes `self` unreadable until `super.init` has returned, and both children
/// here are built before that — so the bar's stored verb cannot capture this controller directly. A box
/// is the smallest thing that closes the gap without making the bar's verb optional at its own call
/// site or deferring the whole build to `viewDidLoad`.
@MainActor
private final class ClosureBox {
    var run: (() -> Void)?
}
#endif
