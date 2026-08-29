// MacCodePanelSurfaces — the RIGHT panel's four surfaces, in AppKit (docs/56 stage D, increment 51).
//
// The workbench (code-server in a pooled `WKWebView`), the host's iOS Simulators, its Android devices,
// and the announced-but-empty Desktop. The strip of tabs over them is this view's SIBLING under
// ``MacCodePanelColumn``; what is here is the surfaces, and NOTHING ELSE.
//
// WHAT EACH SURFACE SAYS IS NOT HERE — it is ``CodePanelPresentation``, one floor down, because the
// phone draws the same four surfaces on its own layout and the words are not a fact about either
// drawing. WHICH SURFACE IS UP IS NOT HERE EITHER, and that is the newer half: the plan, the five
// loops, the parking bracket and the device reports are ``CodePanelSurfaceRuntime``'s, beside the
// words. This file had 116 eight-line windows in common with the phone's controller before that
// carve, and only two of them were `NSView` spellings.
//
// ## What is left, and why it could not descend
//
// Which `NSView` a plan mounts, how a child controller is parented, and the constraints that fill the
// panel. The runtime hands a plan down and this file answers it with AppKit; the LIFETIME question —
// what cancels when a surface leaves — is the runtime's, because it is the same answer on both shells
// and only the frameworks' `.task(id:)`-shaped hole differs.
//
// The collapse animation stays too: it is one gesture on ONE clock with the column's width, and the
// phone has no column to slide.

import AppKit
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacCodePanelSurfaces: NSViewController {
    /// The panel's decision, its loops and its reports — the shell's ONE dependency.
    private let runtime: CodePanelSurfaceRuntime

    /// What is mounted, and under which identity. The identity is what makes an observation callback
    /// that changed nothing cost nothing — a surface rebuilt on every store write would tear down the
    /// workbench several times a second.
    private var mountedKey = ""
    private var mountedChild: NSViewController?

    init(runtime: CodePanelSurfaceRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        view = root
        // The first plan arrives synchronously from this call, so the panel is never blank for a turn.
        runtime.start { [weak self] plan in self?.mount(plan) }
        followCollapse()
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

        if let child = mountedChild {
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

    /// The panel has ONE way of holding a surface: all four edges, no inset. Said once here because
    /// `NSLayoutConstraint` is the only spelling AppKit has for it and repeating it per branch is how
    /// one branch ends up pinned to three edges.
    private func fill(with surface: NSView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func build(_ plan: CodePanelSurfacePlan) -> NSView {
        if let empty = plan.desktop { return MacPanelEmptyStateView(empty) }
        if let device = plan.device {
            switch device {
            case .devices: return hostedDevices(plan.which)
            case let .waiting(label): return MacPanelWaitingView(label)
            case let .empty(reading): return MacPanelEmptyStateView(reading)
            }
        }
        switch plan.code {
        case let .gate(root):
            return MacCodeOpenGateView(projectRoot: root) { [chrome = runtime.chrome] in
                chrome.openCodeProject(root)
            }
        case let .workbench(root, url):
            return MacCodeWorkbenchView(projectRoot: root, url: url)
        case let .waiting(label):
            return MacPanelWaitingView(label)
        case let .empty(reading):
            return MacPanelEmptyStateView(reading)
        case .none:
            return NSView()
        }
    }

    /// The device surface for the tab that is up, as a CHILD controller rather than a bare view.
    ///
    /// Both surfaces are two depths with a drill between them, and both have to hear `viewWillDisappear`
    /// to release a live mirror — an `NSView` added to a hierarchy with no controller above it never
    /// does, and the stream would run on into the tab beside it.
    private func hostedDevices(_ which: CodePanelSurfacePlan.Device?) -> NSView {
        let controller: NSViewController = which == .android
            ? MacAndroidSurface(model: runtime.androidModel)
            : MacSimulatorSurface(model: runtime.simulatorModel)
        addChild(controller)
        mountedChild = controller
        return controller.view
    }

    // MARK: - The collapse

    /// THE COLUMN'S CONTENT LEAVES BEFORE ITS WIDTH DOES (user-reported 2026-08-09: the collapse read
    /// as rough). A panel closing is a width animation, and everything standing in it — an embedded
    /// workbench, a device stage — gets re-laid-out at every intermediate width on the way out. That
    /// reflow is the roughness; it is not the slide. So the content fades first and the empty ground
    /// rides the rest of the slide out, and coming back it is the mirror, arriving as the column lands.
    /// One gesture, one clock — the same contract the titlebar strip and the rail keep.
    private func followCollapse() {
        ObservationFollow.arm(self) { surfaces in
            surfaces.runtime.chrome.codeSidebarCollapsed
        } apply: { surfaces, collapsed in
            // Leaving does not wait at all; ARRIVING waits out most of the column's slide, so the
            // content lands on a column that has already arrived rather than being dragged in with it.
            // SwiftUI spelled that as `.delay(columnSlideDuration * 0.55)` on the reveal curve; AppKit
            // has no delay on an animation group, so the wait is the schedule.
            guard collapsed else {
                let delay = Slate.Motion.columnSlide.duration * Self.revealShare
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak surfaces] in
                    MainActor.assumeIsolated {
                        guard let surfaces, !surfaces.runtime.chrome.codeSidebarCollapsed else { return }
                        surfaces.animateAlpha(to: 1, on: Slate.Motion.reveal)
                    }
                }
                return
            }
            surfaces.animateAlpha(to: 0, on: Slate.Motion.fadeOut)
        }
    }

    /// How much of the column's slide the arriving content sits out.
    private static let revealShare = 0.55

    private func animateAlpha(to alpha: CGFloat, on curve: SlateCurve) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            view.animator().alphaValue = alpha
        }
    }
}
