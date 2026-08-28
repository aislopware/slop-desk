// PhoneSimulatorSurface — the Simulators tab's two depths.
//
// A DRILL, not a split. The panel is one column and the two things it can show — the host's device set,
// and one device being driven — are the same subject at two depths, so they replace each other rather
// than sit side by side. A list beside a stage would spend the width the device needs on rows that are
// only there to be left. On a phone that is not even a trade: 390 points cannot hold both.
//
// THE DIRECTION CARRIES THE DEPTH. Entering, the stage arrives from the trailing edge and the list
// leaves toward the leading one; going back, both reverse. It is the one thing on screen that says
// which way you moved, and it is symmetric — a view's side of the hierarchy does not change with the
// direction of travel.
//
// BOTH ARE MOUNTED MID-TRANSITION, which is why the outgoing view is removed by the animation's
// completion rather than before it starts. The deleted SwiftUI half got this from `ZStack` +
// `.transition`; here it is two sets of constraints alive at once for the length of one beat.
//
// ⚠️ THE STAGE IS KEYED ON THE UDID, not on "a device is selected". Switching devices from the stage is
// possible (the list is one tap away and returns to a different row), and reusing the stage across that
// would feed a second device's frames into a decoder configured with the first one's parameter sets.
// ``PhoneSimulatorStageView`` keys its own screen view the same way; keying here as well is what makes
// the two agree without either one asking the other.
//
// ⚠️ NO `UINavigationController`, though this is a drill and that is what a drill usually is. The panel
// is already a presented surface inside the workspace shell with its own way out, and a nav controller
// would put a second bar with a second back chevron above a header band that already carries one. The
// two depths here are TWO SURFACES, not two screens — the stage's own device header owns the way back.

#if os(iOS)
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhoneSimulatorSurface: UIViewController {
    private let model: SimulatorSidebarModel

    /// What the mounted depth was built for: `nil` before the first mount, `"list"` at the top, and
    /// `"stage:<udid>"` below. A STRING rather than the selection itself, because the identity that
    /// matters is "which surface, for which device" and the two answers have to compare as one value.
    private var mounted: String?
    private var mountedView: UIView?
    private var mountedLeading: NSLayoutConstraint?
    private var mountedTrailing: NSLayoutConstraint?

    /// ⚠️ `withObservationTracking` fires ONCE, so ``follow()`` re-registers from inside its own
    /// `onChange`; `[weak self]` ends a chain when the controller dies but does NOT supersede a live
    /// arm, so a second call would leave two chains multiplying on the same key path.
    private var generation = 0

    init(model: SimulatorSidebarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The panel SINKS (ONE ISLAND, law 1) — both depths stand on the same cream, so the ground is
        // painted once here and neither surface has to know it is being swapped. A dynamic `UIColor` on
        // `backgroundColor` re-resolves itself across a light/dark switch, which is why this half needs
        // no appearance hook where the AppKit one does: there the ground is a resolved `CGColor`.
        view.backgroundColor = Slate.Native.Surface.field
        // Clipped, or the leaving surface slides out over whatever is beside it for the length of the
        // beat: an offset transition without a clip is a view drawn outside its own panel.
        view.clipsToBounds = true
        follow()
    }

    /// The one observation: which depth, for which device.
    private func follow() {
        generation &+= 1
        let generation = generation
        var selection: String?
        withObservationTracking {
            selection = self.model.selection
        } onChange: { [weak self] in
            // The hop is required rather than tidy: `onChange` runs INSIDE the mutation, so re-reading
            // the model from it would observe a half-written value.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    follow()
                }
            }
        }
        let wanted = selection.map { "stage:\($0)" } ?? "list"
        guard wanted != mounted else { return }
        mounted = wanted
        let isEntering = selection != nil
        // ENTERING: the stage arrives from the trailing edge. LEAVING: the list arrives from the leading
        // one. The same two numbers, negated, which is what makes the pair read as one movement.
        let shift = isEntering ? Slate.Metric.space4 : -Slate.Metric.space4
        let surface: UIView
        if isEntering {
            let stage = PhoneSimulatorStageView(model: model)
            // A `UIView` cannot present, and walking the responder chain to find a controller would make
            // the stage's behaviour depend on where it happened to be mounted. The surface that DOES own
            // a controller hands the capability down instead.
            stage.present = { [weak self] popover, anchor in
                popover.popoverPresentationController?.sourceView = anchor
                popover.popoverPresentationController?.sourceRect = anchor.bounds
                self?.present(popover, animated: true)
            }
            surface = stage
        } else {
            surface = PhoneSimulatorDeviceList(model: model) { [model] udid in model.select(udid) }
        }
        swap(to: surface, from: shift)
    }

    /// Mount `surface` offset by `shift` and slide it home, sliding whatever was there out the other
    /// way. The FIRST mount has nothing to leave, so it lands without a beat — an app opening the panel
    /// should not watch its first surface arrive from off-screen.
    private func swap(to surface: UIView, from shift: CGFloat) {
        let outgoing = mountedView
        let outgoingLeading = mountedLeading
        let outgoingTrailing = mountedTrailing

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.alpha = outgoing == nil ? 1 : 0
        view.addSubview(surface)
        let leading = surface.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: outgoing == nil ? 0 : shift,
        )
        let trailing = surface.trailingAnchor.constraint(
            equalTo: view.trailingAnchor, constant: outgoing == nil ? 0 : shift,
        )
        NSLayoutConstraint.activate([
            leading, trailing,
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        mountedView = surface
        mountedLeading = leading
        mountedTrailing = trailing
        guard outgoing != nil else { return }

        // Laid out at the OFFSET before the animation starts, or the first frame of the beat is the
        // whole slide: an unresolved constraint animates from wherever the view happened to be.
        view.layoutIfNeeded()
        leading.constant = 0
        trailing.constant = 0
        outgoingLeading?.constant = -shift
        outgoingTrailing?.constant = -shift
        phoneSimulatorAnimate(Slate.Motion.standard) { [weak self] in
            surface.alpha = 1
            outgoing?.alpha = 0
            self?.view.layoutIfNeeded()
        } completion: {
            outgoing?.removeFromSuperview()
        }
    }
}
#endif
