// PhonePanelSurfacesViewController — the RIGHT panel's four surfaces, on the PHONE (docs/62 stage D).
//
// The workbench (code-server in a pooled `WKWebView`), the host's iOS Simulators, its Android devices,
// and the announced-but-empty Desktop. The bar of tabs over them is this controller's SIBLING under
// ``PhonePanelViewController``; what is here is the surfaces, and NOTHING ELSE.
//
// WHAT EACH SURFACE SAYS IS NOT HERE — it is ``CodePanelPresentation``, one target down, because the
// Mac draws the same four surfaces on its own layout and the words are not a fact about either
// drawing. WHICH SURFACE IS UP IS NOT HERE EITHER, and that is the newer half: the plan, the five
// loops, the parking bracket and the device reports are ``CodePanelSurfaceRuntime``'s, beside the
// words. This controller and `MacCodePanelSurfaces` shared 116 eight-line windows before that carve,
// and only two of them were `UIView` spellings.
//
// ## What is left, and why it could not descend
//
// Which `UIView` a plan mounts, how a child controller is parented, the constraints that fill the
// panel — and the workbench's own teardown, which is the one mount fact the Mac does not have: a
// dismissed sheet must release the pooled webview rather than wait for the last reference to drop.
//
// ## What this controller does NOT own
//
// The three models, and the runtime that reads them. They belong to ``PhonePanelViewController``,
// which belongs to a presentation the reader dismisses and re-opens — and a panel that re-listed every
// device and re-booted every stream on each open would pay the parking rules' bill in the other
// direction. The Mac's column owns them for the mirror-image reason: its strip's reload plate stands
// outside this tree.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhonePanelSurfacesViewController: UIViewController {
    /// The panel's decision, its loops and its reports — the shell's ONE dependency.
    private let runtime: CodePanelSurfaceRuntime

    /// What is mounted, and under which identity. The identity is what makes an observation callback
    /// that changed nothing cost nothing — a surface rebuilt on every store write would tear down the
    /// workbench several times a second.
    private var mountedKey = ""
    private var mountedChild: UIViewController?
    private var mountedWorkbench: PhoneCodeWorkbenchView?

    init(runtime: CodePanelSurfaceRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
        // The first plan arrives synchronously from this call, so the panel is never blank for a turn.
        runtime.start { [weak self] plan in self?.mount(plan) }
    }

    /// Release the pooled workbench and end everything the runtime is following.
    ///
    /// ⚠️ CALLED FROM THE PANEL'S DISMISSAL, not from `deinit`. A `Task` holding this controller weakly
    /// still keeps a socket open, and the parking rules are what release the host encoder — waiting for
    /// the last reference to drop would leave a stream running for however long that takes.
    func teardown() {
        mountedWorkbench?.teardown()
        runtime.teardown()
    }

    // MARK: - The mount

    /// Swap the mounted surface if — and only if — the plan describes a different one.
    ///
    /// ⚠️ THE WORKBENCH'S KEY IS ITS ROOT AND URL, NEVER ITS VEIL. A key that folded in the load state
    /// would remount the pooled webview when the first paint landed, which unparents a live page
    /// mid-navigation to hand it straight back.
    private func mount(_ plan: CodePanelSurfacePlan) {
        let key = plan.identity
        guard key != mountedKey else { return }
        mountedKey = key

        mountedWorkbench?.teardown()
        mountedWorkbench = nil
        if let child = mountedChild {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
            mountedChild = nil
        }
        for subview in view.subviews { subview.removeFromSuperview() }
        // The bracket is the parking rule: the departing device stream stops before the swap and the
        // arriving one starts after it, in one place for both shells.
        runtime.swappingSurface(to: plan) {
            fill(with: build(plan))
        }
    }

    /// The panel has ONE way of holding a surface: all four edges, no inset — deliberately NOT the safe
    /// area, because a device stage fitted to it draws a cream stripe under the mirror, which reads as
    /// the panel having failed to fill the screen rather than as a system inset. The bar above is the
    /// half that hangs off the safe area, and it does that in ``PhonePanelViewController``.
    private func fill(with surface: UIView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func build(_ plan: CodePanelSurfacePlan) -> UIView {
        if let empty = plan.desktop { return PhonePanelEmptyStateView(empty) }
        if let device = plan.device {
            switch device {
            case .devices: return hostedDevices(plan.which)
            case let .waiting(label): return PhonePanelWaitingView(label)
            case let .empty(reading): return PhonePanelEmptyStateView(reading)
            }
        }
        switch plan.code {
        case let .gate(root):
            return PhoneCodeOpenGateView(projectRoot: root) { [chrome = runtime.chrome] in
                chrome.openCodeProject(root)
            }
        case let .workbench(root, url):
            let workbench = PhoneCodeWorkbenchView(
                projectRoot: root, url: url, waitingLabel: Self.workbenchVeilLabel,
            )
            mountedWorkbench = workbench
            return workbench
        case let .waiting(label):
            return PhonePanelWaitingView(label)
        case let .empty(reading):
            return PhonePanelEmptyStateView(reading)
        case .none:
            return UIView()
        }
    }

    /// The workbench veil's caption. Not a ``CodePanelPresentation`` word, and deliberately so: it is
    /// what the MOUNT says while WebKit paints, which is a state the phase machine does not have — the
    /// poll has already reached `.ready`, so there is no phase to ask about it.
    ///
    /// It is still not this view's to SPELL: the Mac's workbench boots behind the same veil saying the
    /// same thing, so the sentence lives on the floor both shells read (docs/56 §3).
    private static var workbenchVeilLabel: String { PanelChromeCopy.workbenchVeilLabel }

    /// The device surface for the tab that is up, as a CHILD controller rather than a bare view.
    ///
    /// Both surfaces are two depths with a drill between them, and both have to hear the panel go away
    /// to release a live mirror — a `UIView` added to a hierarchy with no controller above it never
    /// does, and the stream would run on into the tab beside it.
    private func hostedDevices(_ which: CodePanelSurfacePlan.Device?) -> UIView {
        let controller: UIViewController = which == .android
            ? PhoneAndroidSurface(model: runtime.androidModel)
            : PhoneSimulatorSurface(model: runtime.simulatorModel)
        addChild(controller)
        controller.didMove(toParent: self)
        mountedChild = controller
        return controller.view
    }
}
#endif
