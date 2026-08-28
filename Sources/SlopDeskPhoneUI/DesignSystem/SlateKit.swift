// SlateKit — small reusable chrome controls built on the polished `Slate` token layer (SlateDesign.swift):
//   • `SlatePlateIconButton` — the hover-plate icon button: a borderless SF-Symbol control that grows a
//     faint rounded hover plate, 0.12s small-fade, and answers a tap with THE acknowledgement every
//     chrome button gives. It is the titlebar and sidebar chrome's control.
//   • `CALayer.slateShadow(_:color:in:)` — the `Elevation` rung, cast. The RUNGS are `SlopDeskSlate`;
//     CASTING one is a drawing act, so it lives up here with the framework that draws it (the Mac reads
//     the same rung into a `CALayer`'s `shadowRadius`/`shadowOffset`).
//
// Two controls LEFT this file rather than being rebuilt in it. The `HoverSensor` tracking-area view
// served a top-strip reveal choreography the chrome no longer has: the toggles stand where they stand
// (`WindowSidebarToggle`, `SlopDeskMacUI/MacPanelRail`), so nothing mounted it and no strip appears on
// hover. `PanelTabPlate` left with it — the right panel's four tabs are AppKit now
// (`SlopDeskMacUI/MacPanelTabPlate`), off the one reading in `SlopDeskClientCore/PanelTabs`.

#if os(iOS)
import QuartzCore
import SFSafeSymbols
import SlopDeskSlate
import UIKit

/// The hover-plate icon button: a borderless SF-Symbol control with a faint rounded hover plate.
///
/// ⚠️ ONE OBJECT, WHERE THE DECLARATIVE SPELLING NEEDED THREE, and that is the shape worth knowing
/// rather than a boast. A `ButtonStyle` was the only thing a press edge reached — not the label, not
/// the button — so the fill AND the acknowledgement had to be lifted into a style, which then needed an
/// inner view of its own just to own the counter that made a symbol effect fire. A `UIControl` HAS
/// `isHighlighted`. The style, the wrapper and the counter are one control and two `didSet`s here, and
/// nothing about that three-object dance was transliterated.
///
/// What did NOT change is the vocabulary, because it is the app's and not this control's: the ink and
/// weight of a latched glyph, the XOR that previews the state a press is about to land on, the tray
/// step-up, and THE acknowledgement every chrome button gives a click.
@MainActor
final class SlatePlateIconButton: UIControl {
    /// A LATCHED state — the thing this button turns on is currently on. Distinct from hover, which is
    /// about the pointer: an active plate keeps its fill with the pointer elsewhere, and draws its
    /// glyph in the primary ink at a heavier weight so the state survives on a theme whose hover tint
    /// is faint.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            refreshGlyph()
            refreshFill()
        }
    }

    /// The state this button's verb LANDS ON, for a button that LATCHES something. Setting it moves
    /// the acknowledgement from the press to the landing, which is what lets a chord or a menu row
    /// driving the same flag read exactly like a tap on the plate. `nil` — a plain verb — still
    /// acknowledges: it just fires on the press instead.
    var morphOn: Bool? {
        didSet {
            // `nil` maps to `false`, so a control handed its first `false` after mounting does not
            // bounce for a state it was already in.
            //
            // ⚠️ AND NOT BEFORE THE CONTROL IS MOUNTED. `.onChange` never fires for a view's INITIAL
            // value; a `didSet` fires for every write, including the configuration pass a caller does
            // between `init` and `addSubview`. Without the window guard a button that is latched when
            // it appears bounces once on arrival, for a state change the user did not make.
            guard window != nil, (morphOn ?? false) != (oldValue ?? false) else { return }
            acknowledge()
        }
    }

    /// Set by the plate TRAY — a plate sitting on a tray shares the tray's fill, so both of its states
    /// step up a rung to stay visible against it.
    var onTray = false {
        didSet {
            guard onTray != oldValue else { return }
            refreshFill()
        }
    }

    private let symbol: SFSymbol
    private let glyphSize: CGFloat
    private let action: () -> Void
    private let glyph = UIImageView()
    /// The pointer is over the plate. iPadOS with a trackpad has hover exactly as the Mac does; a
    /// touch-only device simply never sets it, and the plate then reads press-and-latch only.
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            refreshFill()
        }
    }

    init(
        symbol: SFSymbol, size: CGFloat = Slate.Metric.iconSize, plate: CGFloat = Slate.Metric.plate,
        action: @escaping () -> Void = {},
    ) {
        self.symbol = symbol
        glyphSize = size
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: plate, height: plate))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        backgroundColor = .clear

        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: plate),
            heightAnchor.constraint(equalToConstant: plate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        // ⚠️ A `CGColor` on a layer is RESOLVED, not dynamic: it was fixed at the appearance current
        // when it was assigned, and no amount of `Slate.Native.*` being appearance-aware changes that.
        // The registration is the modern `traitCollectionDidChange` and, unlike the override, it names
        // the ONE trait this control actually depends on rather than waking on every trait change.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (control: Self, _: UITraitCollection) in
            control.refreshGlyph()
            control.refreshFill(animated: false)
        }
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        refreshGlyph()
        refreshFill(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The press edge — free here, and the whole reason the fill and the acknowledgement can live on
    /// the control itself rather than in a style wrapped around it.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            refreshFill()
        }
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began, .changed: hovering = true
        default: hovering = false
        }
    }

    @objc
    private func fire() {
        // A plain verb answers the press — its real effect is a round trip away, and a key that waits
        // for the reply reads as one that missed the tap. A LATCHING button stays quiet here and
        // acknowledges in `morphOn`'s `didSet` instead, so the plate and a chord driving the same flag
        // are indistinguishable.
        if morphOn == nil { acknowledge() }
        action()
    }

    /// THE ACKNOWLEDGEMENT — a short symbol bounce, DOWNWARD, because a key that takes a click goes in
    /// before it comes back. Nothing translates and nothing changes size: the control is a fixed
    /// landmark and what changed is the thing it acts on.
    ///
    /// ⚠️ THERE IS NO COUNTER, and its absence is deliberate. The declarative spelling needed one — a
    /// change token, a number bumped so `symbolEffect(_:value:)` would notice and play — because the
    /// effect was DECLARED against a value rather than invoked. UIKit invokes it. A counter nothing
    /// reads is state that can only drift, so what carried over is the effect and not the token.
    private func acknowledge() {
        glyph.addSymbolEffect(.bounce.down, options: .speed(Slate.Anim.ackSpeed))
    }

    /// MEDIUM at rest — at 13pt an SF Symbol in the regular weight goes wispy against a light theme's
    /// paper. SEMIBOLD is the one step above it, and it means latched. Latched is INK AND WEIGHT, never
    /// the accent: a hue carrying state is the pattern this app reversed twice, and primary ink one
    /// weight up says the same thing in the two channels that work on any theme.
    private func refreshGlyph() {
        let ink = active ? Slate.Native.Text.primary : Slate.Native.Text.icon
        glyph.image = UIImage(
            systemName: symbol.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: glyphSize, weight: active ? .semibold : .medium,
            ),
        )?.withTintColor(ink.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
    }

    /// Loose: hover fills faintly, latched sits on the selection tint. On a tray both move up — latched
    /// becomes a REAL raised surface, the only fill that still reads as "this one is on" when its
    /// neighbours already carry the tray's tint.
    ///
    /// A PRESS moves the plate one rung in the direction the tap is about to take it: a loose plate
    /// lights toward "on", a latched one drops toward "off". Every verb on these plates acts on a
    /// remote device, so the only other acknowledgement is the device itself changing a round trip
    /// later.
    ///
    /// Both directions through the same 120ms fade (``Slate/Motion/smallFade``), so a tap shorter than
    /// that still shows: the release fades from wherever the press had reached. `CATransaction` rather
    /// than `UIView.animate` because the property is the LAYER's — a background colour set on the view
    /// would fight the corner radius the plate is drawn with.
    private func refreshFill(animated: Bool = true) {
        let pressed = isHighlighted
        // XOR: pressing previews the latch state the tap lands on.
        let fill: UIColor = if active != pressed {
            onTray ? Slate.Native.Surface.raised : Slate.Native.State.selected
        } else if !hovering, !pressed {
            .clear
        } else {
            onTray ? Slate.Native.State.selected : Slate.Native.State.hover
        }
        let resolved = fill.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = resolved
        CATransaction.commit()
    }
}

extension CALayer {
    /// Cast the shadow of a named ``Slate/Elevation`` rung. The colour defaults to the floating object's
    /// soft black (``Slate/Native/State/shadow``); a summoned card passes the heavier
    /// ``Slate/Native/State/overlayShadow``.
    ///
    /// Radius/y never appear at a call site: the RUNG is the API, here and on the Mac both. ⚠️ Core
    /// Animation wants an explicit `shadowOpacity` where a `shadow(color:radius:y:)` folds it into the
    /// colour — so the rung's colour arrives carrying its own alpha and the opacity is pinned to 1,
    /// rather than the alpha being applied twice.
    @MainActor
    func slateShadow(_ elevation: Slate.Elevation, color: UIColor? = nil, in traits: UITraitCollection) {
        shadowColor = (color ?? Slate.Native.State.shadow).resolvedColor(with: traits).cgColor
        shadowOpacity = 1
        shadowRadius = elevation.radius
        shadowOffset = CGSize(width: 0, height: elevation.y)
    }
}
#endif
