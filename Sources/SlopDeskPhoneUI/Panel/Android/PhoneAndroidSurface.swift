// PhoneAndroidSurface — the Android panel's two depths and the drill between them. This is what the
// right panel mounts for the fourth tab.
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
// why they are pinned to the same four edges rather than stacked.
//
// ⚠️ ANDROID IS A FOURTH TAB, NOT A SECOND HALF OF SIMULATORS. The two panels look alike and share not
// one byte of protocol — `scrcpy` over `adb` against `baguette`'s websocket, Annex-B against AVC,
// packed control messages against JSON envelopes. Nothing in this directory is factored against the
// `PhoneSimulator*` half, and the resemblance is a coincidence rather than an abstraction waiting to
// be found. See ``PhoneAndroidParts`` for that judgement at length.

#if os(iOS)
import Observation
import QuartzCore
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhoneAndroidSurface: UIViewController {
    private let model: AndroidSidebarModel

    private var list: PhoneAndroidDeviceList?
    private var stage: PhoneAndroidStageView?
    /// Which depth is currently drawn — `"list"`, or `"stage:<key>"` for the device it is mirroring. A
    /// STRING rather than a `Bool` because a second device selected while the stage is up is also a
    /// drill: the mirror is minted for one device's parameter sets, so the move between two devices is
    /// the same move as the move into the first. `nil` until the first pass.
    private var depth: String?

    /// ⚠️ Hazard 2's counter. `withObservationTracking` fires once and the callback re-arms, so a
    /// callback from a registration this controller has already replaced must be dropped rather than
    /// allowed to drill a second time.
    private var generation = 0

    init(model: AndroidSidebarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let root = UIView()
        // CLIPPED, and that is what makes the nudge a nudge: a depth translated `space4` past the
        // panel's edge must be cut there rather than drawn over the column beside it.
        root.clipsToBounds = true
        root.backgroundColor = Slate.Native.Surface.field
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        follow()
    }

    /// The panel is going away — a tab switch, or the sheet being dismissed. The stage's mirror has to
    /// be told, because a mounted ``PhoneAndroidScreenView`` holds live gesture state, a sleeping veil
    /// task and a send closure into a socket that is about to be gone.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stage?.unmount()
    }

    // MARK: Following the model

    /// ⚠️ `withObservationTracking` fires ONCE per registration, so the callback re-arms by calling
    /// this again on the next main-queue turn. Only the SELECTION is read here: everything else either
    /// depth draws is tracked by the depth itself, which is what keeps a log line arriving from
    /// rebuilding the surface that contains the console.
    private func follow() {
        generation &+= 1
        let generation = generation

        var selection: String?
        withObservationTracking {
            selection = self.model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        drill(to: selection.map { "stage:\($0)" } ?? Self.listDepth)
    }

    private static let listDepth = "list"

    // MARK: The drill

    private func drill(to next: String) {
        guard next != depth else { return }
        let isFirst = depth == nil
        let isStage = next != Self.listDepth
        depth = next

        // Whichever depth is up is the one leaving; only one of the two is ever non-nil. A stage giving
        // way to ANOTHER stage still has a live mirror in it, and the old one has to go inert before
        // the new one attaches to the same frame sink.
        let outgoing: UIView? = list ?? stage
        list = nil
        stage?.unmount()
        stage = nil

        let incoming: UIView
        if isStage {
            let built = PhoneAndroidStageView(model: model) { [weak self] in
                // The way OUT. Like the way in, it is the SELECTION write that carries the drill, so
                // the stage declares no transition of its own for it.
                self?.model.select(nil)
            }
            stage = built
            incoming = built
        } else {
            let built = PhoneAndroidDeviceList(model: model) { [weak self] device in
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
        // frame written here is overwritten by the constraint engine on the next layout pass — which in
        // a rotating phone is immediately, and the drill silently becomes a cross-fade.
        //
        // ⚠️ AND IT IS A `CATransaction`, not `UIView.animate`, for the reason ``SlateListRowView``
        // records: a `UIView` animation block carries a duration and a curve CASE, never this token's
        // own bezier. `opacity` is the layer property a fade lowers to anyway (docs/62 §3.2).
        let shift = isStage ? Slate.Metric.space4 : -Slate.Metric.space4
        incoming.layer.opacity = 0
        incoming.layer.transform = CATransform3DMakeTranslation(shift, 0, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Slate.Motion.standard.duration)
        CATransaction.setAnimationTimingFunction(Slate.Motion.standard.timingFunction)
        CATransaction.setCompletionBlock {
            outgoing?.removeFromSuperview()
        }
        incoming.layer.opacity = 1
        incoming.layer.transform = CATransform3DIdentity
        outgoing?.layer.opacity = 0
        outgoing?.layer.transform = CATransform3DMakeTranslation(-shift, 0, 0)
        CATransaction.commit()
    }

    private func mount(_ child: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
    /// tap, because a card that lights under the finger and then does nothing is worse than one that
    /// never lit.
    private func enter(_ device: AndroidDevice) {
        guard AndroidPresentation.canEnter(device) else { return }
        model.select(device.key)
    }
}
#endif
