// MacAndroidSurface — the Android panel's two depths and the drill between them, in AppKit
// (docs/56 stage D, increment 52b). This is what ``MacCodePanelSurfaces`` mounts for the fourth tab.
//
// THE LIST AND THE DEVICE ARE ONE SURFACE AT TWO DEPTHS, so the swap between them is a DRILL, not a
// cut. The stage always enters from the trailing side and leaves back that way, the list always from
// the leading side — one direction per view, which is what makes "in" and "out" legible without either
// of them knowing which way the last move went.
//
// The shift is a NUDGE, not a page slide. A full-width push of a live H.264 surface is 200 ms of a
// video layer being composited across the panel to say something a few points of parallax already say;
// the depth cue is the offset's DIRECTION, and the fade carries the rest.
//
// BOTH DEPTHS ARE MOUNTED MID-DRILL, and neither may squeeze the other while they overlap — which is
// why they are pinned to the same four edges rather than stacked. The SwiftUI half says that with a
// `ZStack`; here it is four constraints each.
//
// ⚠️ ANDROID IS A FOURTH TAB, NOT A SECOND HALF OF SIMULATORS. The two panels look alike and share not
// one byte of protocol — `scrcpy` over `adb` against `baguette`'s websocket, Annex-B against AVC,
// packed control messages against JSON envelopes. Nothing in this directory is factored against the
// `MacSimulator*` half, and the resemblance is a coincidence rather than an abstraction waiting to be
// found. See ``MacAndroidParts`` for the one place that judgement was worth writing down at length.

import AppKit
import SlopDeskClientCore // `ObservationFollow` — the one spelling of the re-arm
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacAndroidSurface: NSViewController {
    private let model: AndroidSidebarModel

    private var list: MacAndroidDeviceList?
    private var stage: MacAndroidStageView?
    /// Which depth is currently drawn, so an observation that changed something else does not rebuild
    /// a live mirror. `nil` until the first pass.
    private var depth: Bool?

    init(model: AndroidSidebarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        follow()
    }

    /// The panel is going away — a tab switch, or the column closing. The stage's mirror has to be
    /// told, because a mounted `AndroidScreenNSView` holds live gesture state and a send closure into
    /// a socket that is about to be gone.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        stage?.unmount()
    }

    // MARK: Following the model

    /// ⚠️ Only the SELECTION is read here: everything else either depth draws is tracked by the depth
    /// itself, which is what keeps a log line arriving from rebuilding the surface that contains the
    /// console.
    private func follow() {
        ObservationFollow.arm(self) { surface in
            surface.model.selection != nil
        } apply: { surface, hasSelection in
            surface.drill(to: hasSelection)
        }
    }

    // MARK: The drill

    private func drill(to isStage: Bool) {
        guard isStage != depth else { return }
        let isFirst = depth == nil
        depth = isStage

        let outgoing: NSView? = isStage ? list : stage
        if isStage { list = nil } else { stage?.unmount()
            stage = nil
        }

        let incoming: NSView
        if isStage {
            let built = MacAndroidStageView(model: model)
            stage = built
            incoming = built
        } else {
            let built = MacAndroidDeviceList(model: model) { [weak self] device in
                self?.enter(device)
            }
            list = built
            incoming = built
        }
        mount(incoming)

        guard !isFirst else {
            outgoing?.removeFromSuperview()
            return
        }
        // Enter from `shift`, leave back to it — symmetric, because a view's side of the hierarchy does
        // not change with the direction of travel. The STAGE's side is trailing and the LIST's is
        // leading, ALWAYS, whichever way this particular move went: that is what makes "in" and "out"
        // legible without either view knowing the last direction.
        //
        // ⚠️ THE NUDGE IS A LAYER TRANSFORM, not a frame. Both depths are pinned to four edges, so a
        // frame written here is overwritten by the constraint engine on the next layout pass — which
        // in a resizing panel is immediately, and the drill silently becomes a cross-fade.
        let shift = isStage ? Slate.Metric.space4 : -Slate.Metric.space4
        incoming.wantsLayer = true
        outgoing?.wantsLayer = true
        incoming.alphaValue = 0
        incoming.layer?.transform = CATransform3DMakeTranslation(shift, 0, 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.standard.duration
            context.timingFunction = Slate.Motion.standard.timingFunction
            context.allowsImplicitAnimation = true
            incoming.animator().alphaValue = 1
            incoming.layer?.transform = CATransform3DIdentity
            outgoing?.animator().alphaValue = 0
            outgoing?.layer?.transform = CATransform3DMakeTranslation(-shift, 0, 0)
        } completionHandler: {
            outgoing?.removeFromSuperview()
        }
    }

    private func mount(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// The way IN. It lives here rather than in the list because the selection write is what CARRIES
    /// the drill — the panel's transition vocabulary belongs to the surface that owns both depths, and
    /// the two halves declare no animation of their own for it.
    ///
    /// The GUARD is ``AndroidPresentation/canEnter(_:)``, asked once here and once at the card's own
    /// tap, because a card that lights under the pointer and then does nothing is worse than one that
    /// never lit.
    private func enter(_ device: AndroidDevice) {
        guard AndroidPresentation.canEnter(device) else { return }
        model.select(device.key)
    }
}
