// VideoSurfaceHost — the UIKit mount of one remote-GUI pane (docs/56 §3, the video carve).
//
// This is the phone's twin of `SlopDeskVideoClientMac.MacVideoSurfaceHost`, and the reason it exists
// at all is the same one that gave the Mac a native host: `MetalLayerBackedView` is ALREADY a `UIView`
// that owns the whole client pipeline, and the `AnyView`/SwiftUI seam that used to sit between it and
// the canvas bought nothing but a hosting view over a surface that must take every touch.
//
// WHAT THIS FILE DOES NOT PORT: the deleted `VideoLayerRepresentable`'s `makeUIView`/`updateUIView`
// split existed to answer a question UIKit's imperative world does not ask — "what changed since the
// last render" — because SwiftUI re-ran the whole representable on every render regardless of what
// actually changed. There is no render loop here: the closures in ``VideoPaneSpec`` are fixed at
// mount (`init`) and never re-sent, and the only fields that change after mount are the three
// ``setPaneGates(isActive:inputEnabled:backgroundPointer:)`` primitives — so `init` keeps the
// `makeUIView` half (mount-time wiring, the before/after-`activate` split) and ``applyGates()`` keeps
// only the `updateUIView` half that a gate change actually needs (the read-only-flip re-publish).
// Splitting the mount/gate logic into a separate `build()`/`apply(to:)` pair the way the Mac's
// `MacVideoLayerView` does would buy nothing here: nothing else in this module calls either half
// standalone, unlike the Mac where `MacVideoWindowView`'s SwiftUI body still exists and needs one too.
#if os(iOS)
import QuartzCore
import SlopDeskVideoClient
import SlopDeskVideoProtocol
import UIKit

/// The UIKit twin of the deleted SwiftUI `VideoPaneControls`: the control bridge `VideoSurfaceHost`
/// hands `MetalLayerBackedView`, so the Metal view can publish state upward without importing the
/// container that draws it. Deliberately NOT `ObservableObject` / `@Published` — nothing here renders
/// through SwiftUI's diffing any more, so a state change propagates through one plain closure instead
/// of standing up a Combine pipeline for a single observer.
///
/// `@MainActor`, exactly like the deleted SwiftUI class it replaces: `MetalLayerBackedView` (a
/// `UIView`, itself MainActor-isolated) is the only writer, `VideoSurfaceHost` (also a `UIView`) is
/// the only reader, and ``onSwipePeelChanged`` calls into `VideoSurfaceHost.adoptSwipePeel`, a
/// MainActor method — leaving this un-isolated would be an isolation mismatch at both crossings.
@MainActor
final class VideoPaneControls {
    /// The live content mode (fit/fill), mirrored from `pipeline.contentMode`. NO CURRENT READER: the
    /// SwiftUI footer that showed a fit/fill toggle was one of the 72 deleted files, and nothing in
    /// this carve rebuilds it. Kept so `MetalLayerBackedView`'s existing writes
    /// (`controls?.mode = .fit`, `controls?.mode = pipeline.contentMode`) keep a home rather than
    /// forcing an `#if` around code this file does not own.
    var mode: VideoContentMode = .fit
    /// Whether the viewport is zoomed past 1×. Same "no current reader" note as `mode`.
    var zoomed = false
    /// SWIPE-PEEL chip state (doc 05 §8): `nil` = hidden, already quantized by `SwipePeelPlanner` so a
    /// 120 Hz gesture stream notifies ``onSwipePeelChanged`` at most a few dozen times per gesture.
    var swipePeel: SwipePeelChipState? {
        didSet {
            guard swipePeel != oldValue else { return }
            onSwipePeelChanged?(swipePeel)
        }
    }

    var onResetZoom: () -> Void = {}
    /// Fired on every ``swipePeel`` change. `VideoSurfaceHost` is the one subscriber, animating the
    /// chip through `UIView.animate` where the SwiftUI overlay used to animate through `@Published` +
    /// an implicit `.animation(...)` modifier.
    var onSwipePeelChanged: ((SwipePeelChipState?) -> Void)?
}

/// The swipe-peel progress chip (doc 05 §8): a chevron in a flat circle whose ring fills toward the
/// commit threshold and turns solid the instant a release would navigate — the ENTIRE visible
/// feedback for a native-feeling swipe-back/forward gesture over a remote desktop (the streamed image
/// itself never moves; see `SwipePeelPlanner`'s doc comment for why).
///
/// Ported from the deleted SwiftUI `SwipePeelChipView` onto `CAShapeLayer`s rather than transliterated
/// onto `draw(_:)`: nothing here needs to run per frame, only ``configure(_:)`` mutates layer
/// properties on a state change, and `VideoSurfaceHost.adoptSwipePeel` drives the
/// emergence/scale/opacity that used to be SwiftUI modifiers (`.offset`, `.scaleEffect`, `.opacity`)
/// through `UIView.animate` instead — the same "commit once, don't re-derive every frame" shape
/// `CAShapeLayer` is for.
final class SwipePeelChipView: UIView {
    private let backgroundCircle = CAShapeLayer()
    private let borderCircle = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundCircle.fillColor = UIColor.white.withAlphaComponent(0.82).cgColor
        layer.addSublayer(backgroundCircle)
        borderCircle.fillColor = UIColor.clear.cgColor
        borderCircle.strokeColor = UIColor.black.withAlphaComponent(0.12).cgColor
        borderCircle.lineWidth = 1
        layer.addSublayer(borderCircle)
        progressRing.fillColor = UIColor.clear.cgColor
        progressRing.strokeColor = UIColor.black.withAlphaComponent(0.75).cgColor
        progressRing.lineWidth = 2
        progressRing.lineCap = .round
        progressRing.strokeStart = 0
        progressRing.strokeEnd = 0
        // Rotated -90° so the trim starts at 12 o'clock, matching the SwiftUI ring's
        // `.rotationEffect(.degrees(-90))`. `CAShapeLayer`'s default `anchorPoint` is (0.5, 0.5), so
        // this rotates about the circle's own centre with no extra bookkeeping.
        progressRing.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        layer.addSublayer(progressRing)
        chevron.contentMode = .center
        addSubview(chevron)
        // The SwiftUI circle carried its own drop shadow (`color: .black.opacity(0.25), radius: 4,
        // y: 1`); the container's shadow would sit behind the video instead.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let local = CGRect(origin: .zero, size: bounds.size)
        backgroundCircle.frame = bounds
        borderCircle.frame = bounds
        progressRing.frame = bounds
        chevron.frame = bounds
        let circlePath = UIBezierPath(ovalIn: local).cgPath
        backgroundCircle.path = circlePath
        borderCircle.path = circlePath
        // Inset by the stroke's half-width so the ring's line sits fully inside the chip's frame,
        // matching the SwiftUI `Circle().trim(...).stroke(lineWidth: 2)` at the same frame.
        progressRing.path = UIBezierPath(ovalIn: local.insetBy(dx: 1, dy: 1)).cgPath
    }

    /// Applies one chip state's colours, fill and chevron — everything that is NOT the emergence
    /// tuck / confirm-pulse scale / dim-hold opacity, which `VideoSurfaceHost.adoptSwipePeel` animates
    /// on the view itself (those are transform/alpha, not layer content, so animating them here would
    /// fight the caller's `UIView.animate` block).
    func configure(_ state: SwipePeelChipState) {
        backgroundCircle.fillColor = UIColor.white.withAlphaComponent(state.committed ? 0.95 : 0.82).cgColor
        progressRing.strokeEnd = state.progress
        // The solid COMMITTED state REPLACES the progress ring, exactly as the SwiftUI view's
        // `.opacity(state.committed ? 0 : 1)` on the ring did.
        progressRing.opacity = state.committed ? 0 : 1
        let symbolName = state.direction == .back ? "chevron.left" : "chevron.right"
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        chevron.image = UIImage(systemName: symbolName, withConfiguration: config)
        chevron.tintColor = UIColor.black.withAlphaComponent(state.committed ? 0.9 : 0.45)
    }
}

/// The UIKit mount of one remote-GUI pane — `MacVideoSurfaceHost`'s phone twin, and the app target's
/// one entry point into the client video pipeline. Owns ``MetalLayerBackedView`` (the pixel + input
/// surface, unchanged by this carve) and the swipe-peel chip overlay, and structurally satisfies
/// `SlopDeskWorkspaceCore.RemoteSurfaceHosting` — this module deliberately never imports
/// `SlopDeskWorkspaceCore` (the whole reason the seam exists), so the three members below are spelled
/// to match that protocol rather than declared against it, and the app target declares the
/// conformance RETROACTIVELY, exactly like `WindowFeedChannel: @retroactive HostWindowFeedLink`:
/// ```swift
/// import SlopDeskVideoClientPhone
/// import SlopDeskWorkspaceCore
/// extension VideoSurfaceHost: @retroactive RemoteSurfaceHosting {}
/// VideoWindowFactory.shared = { descriptor, context in
///     VideoSurfaceHost(VideoPaneSpec(title: descriptor.title, ...))
/// }
/// ```
public final class VideoSurfaceHost: UIView {
    /// The Metal-backed pane view: pixels + the whole touch/pointer/keyboard translation. Owned as a
    /// subview; it owns the decode pipeline (sockets, decoder, display link) for its lifetime.
    private let surface: MetalLayerBackedView
    /// The control bridge, owned here for this host's lifetime. `surface` publishes the swipe-peel
    /// state onto it; ``adoptSwipePeel(_:)`` reads it back through ``VideoPaneControls/onSwipePeelChanged``.
    private let controls = VideoPaneControls()
    /// The swipe-peel feedback chip, pinned over the surface and never hit-testable — a touch at the
    /// pane edge during the ~520 ms confirm hold must still reach the remote window through `surface`.
    private let peelChip = SwipePeelChipView()
    private var peelLeading: NSLayoutConstraint!
    private var peelTrailing: NSLayoutConstraint!

    /// The mount-time spec. Kept (rather than discarded after `init`) so
    /// ``setPaneGates(isActive:inputEnabled:backgroundPointer:)`` can re-run the closures it was built
    /// with against ``applyGates()`` — the three gate fields are the ONLY ones that field ever
    /// mutates; every closure is fixed at mount.
    private var spec: VideoPaneSpec

    public init(_ spec: VideoPaneSpec) {
        self.spec = spec
        surface = MetalLayerBackedView(frame: .zero)
        super.init(frame: .zero)

        surface.controls = controls
        surface.isActive = spec.isActive
        surface.inputEnabled = spec.inputEnabled
        surface.onActivate = spec.onActivate
        // BEFORE activate — nil-ness picks snap vs. host-follow negotiation at session construction,
        // and the first decoded frame / first cadence-or-stats push / an immediate
        // `helloAck(accepted: false)` must each find their sink already set (mirrors the Mac's
        // `MacVideoLayerView.build()`).
        surface.onStreamNativeSize = spec.onStreamNativeSize
        surface.onWindowGeometryReady = spec.onWindowGeometryReady
        surface.onStreamCadenceReady = spec.onStreamCadenceReady
        surface.onStreamBitrateReady = spec.onStreamBitrateReady
        surface.onNetworkStatsReady = spec.onNetworkStatsReady
        surface.onStreamStallReady = spec.onStreamStallChanged
        surface.onSessionRejectedReady = spec.onSessionRejected
        surface.activate(connection: spec.connection)
        // AFTER activate — `pipeline.*` no-ops until the session is up, so publishing now is safe, and
        // these are the sinks a read-only-flip later withdraws/restores through `applyGates()`.
        surface.onKeyInjectorReady = spec.onKeyInjectorReady
        surface.publishKeyInjector()
        surface.onResizeInjectorReady = spec.onResizeInjectorReady
        surface.publishResizeInjector()
        surface.onViewportInjectorReady = spec.onViewportInjectorReady
        surface.publishViewportInjector()
        surface.onInputReleaseReady = spec.onInputReleaseReady
        surface.publishInputReleaseInjector()
        surface.onStreamSettingsInjectorReady = spec.onStreamSettingsInjectorReady
        surface.publishStreamSettingsInjector()
        surface.onAudioInjectorReady = spec.onAudioInjectorReady
        surface.publishAudioInjector()
        surface.onPrivacyInjectorReady = spec.onPrivacyInjectorReady
        surface.publishPrivacyInjector()

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        peelChip.isUserInteractionEnabled = false
        peelChip.alpha = 0
        peelChip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(peelChip)
        peelLeading = peelChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        peelTrailing = peelChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        NSLayoutConstraint.activate([
            peelChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            peelChip.widthAnchor.constraint(equalToConstant: 36),
            peelChip.heightAnchor.constraint(equalToConstant: 36),
        ])
        controls.onSwipePeelChanged = { [weak self] state in self?.adoptSwipePeel(state) }

        // Accessibility rides the CONTAINER, not the Metal view: the pixels have no structure to
        // expose — the same rule `MacVideoSurfaceHost` follows.
        isAccessibilityElement = true
        accessibilityLabel = "Remote GUI window: \(spec.title)"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: RemoteSurfaceHosting (declared retroactively by the app target — see the type doc comment)

    /// The view to add as a subview. This container — the Metal view and the peel chip are its
    /// subviews and are never handed out separately.
    public var surfaceView: UIView { self }

    /// The UIKit twin of `updateUIView`: an imperative canvas has no render pass to re-run this from,
    /// so the three gates that change at runtime are pushed explicitly and re-run through
    /// ``applyGates()`` — including its read-only-flip branch, the ONLY thing that withdraws and
    /// restores the host-affecting injector sinks. This is the SOLE path by which the read-only LOCK
    /// reaches the host.
    public func setPaneGates(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool) {
        spec.isActive = isActive
        spec.inputEnabled = inputEnabled
        spec.backgroundPointer = backgroundPointer
        applyGates()
    }

    /// The UIKit twin of `dismantleUIView`. Removing this view from its superview is NOT enough — the
    /// session owns two UDP sockets, a VideoToolbox decoder and a display link, none of which a
    /// `removeFromSuperview` touches.
    public func detachSurface() { surface.deactivate() }

    // MARK: Per-gate-change publish (the deleted `VideoLayerRepresentable.updateUIView` twin)

    private func applyGates() {
        surface.isActive = spec.isActive
        // READ-ONLY INPUT GATE: on a FLIP, re-publish every sink the seam withholds while read-only —
        // locking a live pane withdraws them, unlocking restores them, with no view rebuild. The
        // viewport sink is NOT re-published here (it is never withheld), matching `MetalLayerBackedView`'s
        // own comment on why fit/zoom/lock stay live on a locked pane.
        let inputGateFlipped = surface.inputEnabled != spec.inputEnabled
        surface.inputEnabled = spec.inputEnabled
        surface.onActivate = spec.onActivate
        surface.onStreamNativeSize = spec.onStreamNativeSize
        surface.onWindowGeometryReady = spec.onWindowGeometryReady
        surface.onStreamCadenceReady = spec.onStreamCadenceReady
        surface.onStreamBitrateReady = spec.onStreamBitrateReady
        surface.onNetworkStatsReady = spec.onNetworkStatsReady
        surface.onStreamStallReady = spec.onStreamStallChanged
        surface.onSessionRejectedReady = spec.onSessionRejected
        // Re-run on every gate change, not only when `connection` differs — `VideoWindowPipeline.activate`
        // is idempotent against an unchanged connection (a same-connection re-activate is a documented
        // no-op), so this costs nothing and keeps `applyGates` one straight-line function instead of a
        // second "did the connection change" branch to get wrong.
        surface.activate(connection: spec.connection)
        guard inputGateFlipped else { return }
        surface.onKeyInjectorReady = spec.onKeyInjectorReady
        surface.publishKeyInjector()
        surface.onResizeInjectorReady = spec.onResizeInjectorReady
        surface.publishResizeInjector()
        surface.onInputReleaseReady = spec.onInputReleaseReady
        surface.publishInputReleaseInjector()
        surface.onStreamSettingsInjectorReady = spec.onStreamSettingsInjectorReady
        surface.publishStreamSettingsInjector()
        surface.onAudioInjectorReady = spec.onAudioInjectorReady
        surface.publishAudioInjector()
        surface.onPrivacyInjectorReady = spec.onPrivacyInjectorReady
        surface.publishPrivacyInjector()
    }

    // MARK: Swipe-peel chip (doc 05 §8)

    /// Applies one swipe-peel chip state (from ``VideoPaneControls/onSwipePeelChanged``), porting the
    /// deleted SwiftUI `SwipePeelOverlay`'s three visible knobs onto UIKit's imperative animation API:
    /// which EDGE the chip sits on, the emergence TUCK (how far it has slid out from the edge as
    /// progress grows), and the confirm-pulse DIM HOLD. The 0.15 s curve is the SwiftUI overlay's own
    /// `.timingCurve(0, 0, 0.58, 1, duration: 0.15)`, carried over as a `UIViewPropertyAnimator`
    /// timing curve rather than approximated with a stock UIKit curve, so the emergence reads
    /// identically to the Mac's (still-SwiftUI) chip.
    private func adoptSwipePeel(_ state: SwipePeelChipState?) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if let state {
            // Edge alignment lives INSIDE the state branch so a fading forward-chip keeps ITS edge —
            // the SwiftUI overlay's own rule: recomputing alignment from `nil` would yank a departing
            // chip across to the leading edge mid-fade.
            let onLeading = state.direction == .back
            peelLeading.isActive = onLeading
            peelTrailing.isActive = !onLeading
            peelChip.configure(state)
        }
        let tuck: CGFloat = reduceMotion ? 0 : CGFloat((1 - (state?.progress ?? 1)) * 12)
        let sign: CGFloat = state?.direction == .back ? -1 : 1
        let scale: CGFloat =
            if reduceMotion {
                1
            } else if state?.confirming == true {
                1.12
            } else if state?.committed == true {
                1.06
            } else {
                1
            }
        // DIM HOLD: the confirm pulse plays inside the curve below, then the chip holds at low
        // opacity until the driver clears it (`SwipePeelChipDriver.confirmHold`) — the hold is what
        // spans the inject→capture→stream round trip; fading straight to 0 would end the visible
        // acknowledgement before the host's own navigation lands.
        let alpha: CGFloat = state == nil ? 0 : (state?.confirming == true ? 0.35 : 1)
        let curve = UICubicTimingParameters(controlPoint1: CGPoint.zero, controlPoint2: CGPoint(x: 0.58, y: 1))
        let animator = UIViewPropertyAnimator(duration: 0.15, timingParameters: curve)
        animator.addAnimations { [peelChip] in
            peelChip.transform = CGAffineTransform(translationX: sign * tuck, y: 0).scaledBy(x: scale, y: scale)
            peelChip.alpha = alpha
        }
        animator.startAnimation()
    }
}
#endif
