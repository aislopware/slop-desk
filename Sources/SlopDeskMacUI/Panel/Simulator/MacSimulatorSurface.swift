// MacSimulatorSurface — the Simulators tab's two depths, in AppKit (docs/56 stage D, increment 52a).
//
// A DRILL, not a split. The panel is one column and the two things it can show — the host's device set,
// and one device being driven — are the same subject at two depths, so they replace each other rather
// than sit side by side. A list beside a stage would spend the width the device needs on rows that are
// only there to be left.
//
// THE DIRECTION CARRIES THE DEPTH. Entering, the stage arrives from the trailing edge and the list
// leaves toward the leading one; going back, both reverse. It is the one thing on screen that says
// which way you moved, and it is symmetric — a view's side of the hierarchy does not change with the
// direction of travel.
//
// BOTH ARE MOUNTED MID-TRANSITION, which is why the outgoing view is removed by the animation's
// completion rather than before it starts. The phone gets this from `ZStack` + `.transition`; here it is
// two sets of constraints alive at once for the length of one beat.
//
// ⚠️ THE STAGE IS KEYED ON THE UDID, not on "a device is selected". Switching devices from the stage is
// possible (the list is one click away and returns to a different row), and reusing the stage across
// that would feed a second device's frames into a decoder configured with the first one's parameter
// sets. ``MacSimulatorStageView`` keys its own screen view the same way; keying here as well is what
// makes the two agree without either one asking the other.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacSimulatorSurface: NSViewController {
    private let model: SimulatorSidebarModel

    /// What the mounted depth was built for: `nil` before the first mount, `"list"` at the top, and
    /// `"stage:<udid>"` below. A STRING rather than the selection itself, because the identity that
    /// matters is "which surface, for which device" and the two answers have to compare as one value.
    private var mounted: String?
    private var mountedView: NSView?
    private var mountedLeading: NSLayoutConstraint?
    private var mountedTrailing: NSLayoutConstraint?

    init(model: SimulatorSidebarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        // ⚠️ `viewDidChangeEffectiveAppearance` is `NSView`'s, NOT `NSViewController`'s. A CGColor is a
        // resolved colour rather than a dynamic one, so a ground painted once survives a light/dark
        // switch as the OLD theme's cream — and the callback that would repaint it does not exist on
        // the controller. `MacModalShield` carries the hook, which is why the root is one.
        let root = MacModalShield(overlay: nil)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.onAppearanceChange = { [weak root] in
            root?.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
        // The panel SINKS (ONE ISLAND, law 1) — both depths stand on the same cream, so the ground is
        // painted once here and neither surface has to know it is being swapped.
        root.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        // Clipped, or the leaving surface slides out over the column beside it for the length of the
        // beat: an offset transition without a clip is a view drawn outside its own panel.
        root.layer?.masksToBounds = true
        view = root
        follow()
    }

    /// The one observation: which depth, for which device.
    private func follow() {
        var selection: String?
        withObservationTracking {
            selection = self.model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        let wanted = selection.map { "stage:\($0)" } ?? "list"
        guard wanted != mounted else { return }
        let isEntering = selection != nil
        mounted = wanted
        // ENTERING: the stage arrives from the trailing edge. LEAVING: the list arrives from the leading
        // one. The same two numbers, negated, which is what makes the pair read as one movement.
        let shift = isEntering ? Slate.Metric.space4 : -Slate.Metric.space4
        let surface: NSView = isEntering
            ? MacSimulatorStageView(model: model)
            : MacSimulatorDeviceList(model: model) { [model] udid in model.select(udid) }
        swap(to: surface, from: shift)
    }

    /// Mount `surface` offset by `shift` and slide it home, sliding whatever was there out the other
    /// way. The FIRST mount has nothing to leave, so it lands without a beat — an app opening the panel
    /// should not watch its first surface arrive from off-screen.
    private func swap(to surface: NSView, from shift: CGFloat) {
        let outgoing = mountedView
        let outgoingLeading = mountedLeading
        let outgoingTrailing = mountedTrailing

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.alphaValue = outgoing == nil ? 1 : 0
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
        view.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.standard.duration
            context.timingFunction = Slate.Motion.standard.timingFunction
            context.allowsImplicitAnimation = true
            leading.animator().constant = 0
            trailing.animator().constant = 0
            outgoingLeading?.animator().constant = -shift
            outgoingTrailing?.animator().constant = -shift
            surface.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
            view.layoutSubtreeIfNeeded()
        } completionHandler: {
            // Main-actor isolated inside a `@Sendable` handler AppKit always runs on the main thread
            // without having annotated it — the assertion is the honest spelling, and it traps rather
            // than corrupting a view tree if that ever stops holding.
            MainActor.assumeIsolated { outgoing?.removeFromSuperview() }
        }
    }
}
