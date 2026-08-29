// PaneMoveAffordanceView — "grab this pane and put it somewhere else", in UIKit (docs/62 stage E.2).
//
// Two drawings and no decisions. The HANDLE is a short pill near the top of a leaf that a finger drags;
// the OVERLAY is what the canvas shows while that drag is in flight — the zone preview under the finger,
// a dashed outline around the pane that was lifted, and a chip pinned to the finger naming what a release
// would do. Neither of them resolves anything: where the finger is, which zone that lands in, and what a
// release commits are ``PaneCanvasDragController``'s, and the rects the previews are drawn at are
// ``PaneDropGeometry``'s. This file decides which SHAPE goes where and nothing else.
//
// THE DRAG MUTATES NOTHING UNTIL THE RELEASE, which is the remote-app rule rather than a style. A finger
// crossing a pane produces sixty resolutions a second; committing any of them would push sixty tree ops
// down the wire and re-solve sixty terminal grids for a gesture the user has not finished making. So the
// gesture only re-points the controller's view-local `move`, the overlay reads it, and exactly one store
// op is committed on release.
//
// WHY A RAW TOUCH SEQUENCE AND NOT A `UIPanGestureRecognizer`. The strip lives on top of a terminal
// surface that runs its own recognisers for selection and the edit menu, and a pan recogniser added here
// negotiates with those through the failure-requirement graph — which is where a grab pill that "sometimes
// does not take" comes from. `touchesBegan`/`Moved`/`Ended` on a view whose hit region IS the strip has no
// negotiation to lose: the strip either got the touch or it did not. It also gives the phase latch below
// somewhere honest to live, because a recogniser's `.cancelled` state is the framework's opinion about the
// gesture and the latch is this view's opinion about whether it may still report one.
//
// THE HIT REGION IS THE STRIP, NOT THE LEAF. The handle is framed to the whole leaf so its pill can be
// placed against the leaf's own width, and then ``point(inside:with:)`` narrows the touchable area back
// down to the strip rect. Everything else in the leaf falls through to the terminal underneath, which is
// the whole pane — a handle that swallowed taps over its leaf would make the pane unusable to gain an
// affordance nobody asked for.
//
// ⚠️ THE FIVE FIGURES ARE ON THE LADDER NOW — ``Slate/DropPreview``. This header used to say they "are
// not on the ladder yet … waiting on a `Slate.DropPreview.*` rung to be minted", and it listed them: the
// preview's rim widths, its two washes' alphas and the dash pattern, restated by the AppKit twin. They
// were the last pair in the client still spelled across a framework boundary — the one place where two
// copies of a number have no compiler, no gate and no reader holding both files open, because an AppKit
// file and a UIKit file share no import. `PaneDropPreviewArt.swift` carries the argument in full.
//
// WHAT ESCAPE DOES, AND WHERE IT IS READ. Not here. This handle never touches the keyboard: a canvas full
// of them each grabbing first responder would be N views fighting over one key, with whichever won
// deciding for every pane. `SplitCanvasView` reads the key once, in `pressesBegan`, and calls
// ``PaneMoveHandleView/cancelDrag()`` on the handle that is actually tracking. That call is the point —
// clearing the controller's `move` alone was the original defect on both platforms, because the next touch
// frame simply refilled it and the release committed the landing the user had explicitly backed out of.
// The latch is what makes a bail-out stick: after it, every remaining event of the same press is absorbed.

#if os(iOS)
import SFSafeSymbols // the mark's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceModel
import UIKit

// MARK: - The grab handle

/// One leaf's grab pill: the door into a pane move, and the only interactive part of this file.
///
/// Framed to its leaf, touchable only over its strip — see the file header for why the two differ. The
/// four callbacks are the whole of its outward vocabulary, and every one of them is a REPORT rather than
/// a request: this view says where the finger is and what happened to it, and the canvas layer that
/// mounted it decides what any of that means.
@MainActor
final class PaneMoveHandleView: UIView {
    /// Which pane this handle lifts. Carried on the view rather than captured in its callbacks so the
    /// canvas can re-point the closures once, at mint time, and look the current leaf up by identity when
    /// one fires — a leaf's RECT is re-solved on every layout pass and a closure holding a stale one
    /// would resolve the drop against last frame's geometry.
    let paneID: PaneID

    /// The finger moved past the slop and is still down. Reported in the canvas layer's coordinates.
    var onDragChanged: ((PaneID, CGPoint) -> Void)?
    /// The finger came up after a real drag. This is the ONE report that commits anything.
    var onDragEnded: ((PaneID, CGPoint) -> Void)?
    /// The drag ended without committing — a bail-out, a system cancel, or this handle being torn out of
    /// the canvas while the finger was still down. Owed exactly once per begin.
    var onDragInterrupted: ((PaneID) -> Void)?
    /// The finger came up without ever passing the slop. A tap on the strip focuses the pane.
    var onTap: ((PaneID) -> Void)?

    /// Whether the pane under this pill streams UNTHEMED content — a `.desktop` video feed rather than a
    /// terminal. A tertiary pill tuned to the terminal palette vanishes over an arbitrary streamed
    /// desktop, so an unthemed leaf gets a small plate under the bar in the same chip voice the rest of
    /// the over-video chrome uses. Terminal leaves keep the flat bar.
    var contentIsUnthemed = false {
        didSet {
            guard contentIsUnthemed != oldValue else { return }
            plate.alpha = contentIsUnthemed ? 1 : 0
        }
    }

    /// Where the press is, and why three states rather than a `Bool`.
    ///
    /// `.pressed` and `.dragging` are not the same thing: a touch that has landed on the strip but not yet
    /// travelled the slop is still a candidate TAP, and reporting it as a drag is how tap-to-focus becomes
    /// unreachable. `.cancelled` is the state neither of the other two can express — the finger is still
    /// down, so the gesture is not over, and nothing more may be reported, so it is not running either.
    /// One value with named cases rather than two flags, because two flags over one gesture would need a
    /// rule for every pair of their states and half of those pairs are unreachable.
    private enum Phase {
        case idle
        case pressed
        case dragging
        case cancelled
    }

    private var phase = Phase.idle
    /// Where the press landed, in this view's own space — the origin the slop is measured from.
    private var anchor: CGPoint = .zero

    /// The pill itself: a bar, over a plate that is only ever visible on unthemed content.
    private let bar = UIView()
    private let plate = UIView()

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        // Nothing here draws a background, and the leaf underneath must stay visible through the whole
        // handle — only the two capsules are ink.
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        plate.alpha = 0
        plate.layer.borderWidth = Slate.Metric.hairline
        addSubview(plate)

        bar.layer.masksToBounds = true
        addSubview(bar)

        paintInks()
        // The deprecated `traitCollectionDidChange` is barred on this platform; this is the supported
        // door, and it fires only for the trait actually named.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.paintInks()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: The pill's geometry

    /// The touchable strip, at the top of the leaf and centred across it.
    ///
    /// ``Slate/GrabPill`` owns every number in here, including the width's dependence on the leaf: a strip
    /// sized as a share of its pane, clamped at both ends, is what keeps one affordance recognisable
    /// across a full-width pane and a narrow column. The satellite window's strip on the Mac reads the
    /// same function, which is the whole reason it is a function on the floor rather than a line here.
    private var stripFrame: CGRect {
        let width = Slate.GrabPill.stripWidth(forLeafWidth: bounds.width)
        return CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: 0,
            width: width,
            height: Slate.GrabPill.stripHeight,
        )
    }

    /// The hit region, narrowed from the leaf to the strip. This one override is what lets the handle be
    /// framed to its pane without swallowing the pane's own touches.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        stripFrame.contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Placement inside a layout pass must not animate: the strip is re-placed on every solved layout,
        // and an implicit action would leave the pill sliding after a rotation or a divider drag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let strip = stripFrame
        let centre = CGPoint(x: strip.midX, y: strip.midY)
        bar.bounds = CGRect(
            x: 0, y: 0, width: Slate.GrabPill.barWidth, height: Slate.GrabPill.barHeight,
        )
        bar.center = centre
        bar.layer.cornerRadius = Slate.GrabPill.barHeight / 2
        plate.bounds = CGRect(
            x: 0, y: 0, width: Slate.GrabPill.plateWidth, height: Slate.GrabPill.plateHeight,
        )
        plate.center = centre
        plate.layer.cornerRadius = Slate.GrabPill.plateHeight / 2
        // The chip elevation, in UIKit's sign convention: `Slate.Elevation`'s `y` is stated for a
        // coordinate space whose axis points up, and this one's points down — the helper carries that
        // flip, which is why it is a helper.
        plate.layer.slateShadow(.chip, in: traitCollection)
        CATransaction.commit()
    }

    /// Every colour this view spends, re-resolved together.
    ///
    /// Whether the pill is DRAWN AT ALL is ``PaneGrabPill/isRevealed(input:hovering:isDragging:)``'s and
    /// not this view's: touch reveals it unconditionally, and the rule saying so is on the floor because
    /// the phone half once spelled `hovering || isDragging` inline — with nothing on a touch screen ever
    /// writing `hovering`, so the pill was never drawn and the move gesture had no door at all. Passing
    /// `hovering: false` here is not a shrug either; it is the truth about a finger, and the floor is what
    /// turns that truth into a verdict.
    private func paintInks() {
        let dragging = phase == .dragging
        let revealed = PaneGrabPill.isRevealed(
            input: .touch, hovering: false, isDragging: dragging,
        )
        bar.alpha = revealed ? 1 : 0
        bar.backgroundColor = dragging ? Slate.Native.State.accent : Slate.Native.Text.tertiary
        plate.backgroundColor = Slate.Native.Surface.face
        plate.layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
    }

    /// The press feedback, which on this platform replaces the pointer's hover growth.
    ///
    /// ``Slate/GrabPill/hoverScale`` is the rung either way — the question "how much bigger does this pill
    /// get when it is being addressed" has one answer, and a cursor arriving over it and a finger landing
    /// on it are two spellings of being addressed. A finger cannot hover, so a phone that only grew on
    /// hover would never grow at all, and the one moment a user needs confirmation that the strip took the
    /// touch is the moment their finger is covering it.
    private func setEngaged(_ engaged: Bool, animated: Bool) {
        let scale = engaged ? Slate.GrabPill.hoverScale : 1
        // `[weak self]` even here: the block outlives this call in the animated arm, and a handle whose
        // pane closed mid-press is exactly the case where it would still be pending.
        let apply = { [weak self] in
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            self?.bar.transform = transform
            self?.plate.transform = transform
        }
        guard animated, window != nil else {
            apply()
            return
        }
        UIView.animate(
            withDuration: Slate.Motion.dividerHover.duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: apply,
        )
    }

    // MARK: The gesture

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, phase == .idle else {
            super.touchesBegan(touches, with: event)
            return
        }
        phase = .pressed
        anchor = touch.location(in: self)
        setEngaged(true, animated: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with _: UIEvent?) {
        guard let touch = touches.first else { return }
        switch phase {
        // A bailed-out press keeps arriving until the finger lifts, and absorbing it is the whole point
        // of the state: the alternative is a tremor un-cancelling a cancel the user has already looked
        // away from.
        case .cancelled,
             .idle:
            return
        case .pressed:
            // ``PaneGrabPill/minimumDragDistance(_:)``'s FINGER slop, not a mouse's. A touch that lands
            // and lifts wanders several points on the way, so the pointer's 2pt turned nearly every tap
            // on this strip into a drag and left the tap-to-focus underneath unreachable.
            let travelled = touch.location(in: self)
            let dx = travelled.x - anchor.x
            let dy = travelled.y - anchor.y
            guard (dx * dx + dy * dy).squareRoot()
                >= PaneGrabPill.minimumDragDistance(.touch) else { return }
            phase = .dragging
            paintInks()
        case .dragging:
            break
        }
        report(touch, to: onDragChanged)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent?) {
        guard let touch = touches.first else { return }
        let ending = phase
        // Cleared BEFORE the callback, and that ordering is load-bearing: a committed drop can close this
        // very pane, which tears this handle out of the canvas inside the call — and the unmount safety
        // net below must then find nothing outstanding rather than report a committed drop as an
        // interruption.
        phase = .idle
        setEngaged(false, animated: true)
        paintInks()
        switch ending {
        case .idle: break
        case .pressed: onTap?(paneID)
        case .dragging: report(touch, to: onDragEnded)
        // The finger finally came up on a bail-out. The controller was told at the moment of the cancel;
        // there is nothing owed here but the latch reset above.
        case .cancelled: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setEngaged(false, animated: false)
        releaseDrag()
    }

    /// Hand the touch's location to a callback in the CANVAS LAYER's space, which is the space the solver
    /// stated its leaf rects in — the drop resolves a point against those rects, so a point measured in
    /// this handle's own bounds would resolve against the wrong origin on every leaf but the first.
    private func report(_ touch: UITouch, to callback: ((PaneID, CGPoint) -> Void)?) {
        guard let superview else { return }
        callback?(paneID, touch.location(in: superview))
    }

    // MARK: The two ways a drag ends without a release

    /// The bail-out, called by the canvas when the cancel key is read. Latches this press inert; the
    /// finger may still be down and every remaining event of it is now absorbed.
    ///
    /// Not the same call as ``releaseDrag()``, and the difference is the finger: this one leaves a press
    /// in flight that still owes a `touchesEnded`, so it may not return the latch to `.idle` — doing so
    /// would let the very next `touchesMoved` start a fresh drag from the middle of a gesture the user
    /// has already abandoned.
    func cancelDrag() {
        guard phase == .dragging else { return }
        phase = .cancelled
        setEngaged(false, animated: true)
        paintInks()
        onDragInterrupted?(paneID)
    }

    /// The teardown net. Owed from a system cancel and from this handle leaving the view tree mid-press,
    /// and idempotent through the latch so it does not matter which arrives first.
    ///
    /// The unmount case is not hypothetical and it is not recoverable if it is missed: the pane closes, or
    /// its tab is evicted, and the drag is stranded with the controller's `move` non-nil forever — which
    /// wedges the hit-test gate on EVERY other handle in the workspace for the rest of the session.
    /// Silently: no crash, no log, just pills that stop responding.
    private func releaseDrag() {
        guard phase != .idle else { return }
        let wasDragging = phase == .dragging
        phase = .idle
        paintInks()
        if wasDragging { onDragInterrupted?(paneID) }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseDrag() }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        // Both doors, because they are not the same door: a handle can be pulled out of its band while the
        // band itself stays on screen (its leaf closed), and a whole tab layer can leave the window with
        // every handle still parented (the tab was evicted).
        if newSuperview == nil { releaseDrag() }
    }
}

// MARK: - The move overlay

/// Everything the canvas draws ABOVE its panes while a move is in flight. Purely visual — it never takes
/// a touch, because the only finger on screen belongs to the handle that started the drag.
///
/// Three marks, and they answer three different questions. The ZONE preview says what a release commits;
/// the LIFTED outline says which pane is in the air, so a swap reads as an exchange rather than as one
/// pane appearing somewhere; the CHIP says the answer in words, because a wash over a rectangle cannot
/// distinguish "swap with this" from "split beside this" to a user who has not learned the vocabulary yet.
@MainActor
final class PaneMoveOverlayView: UIView {
    /// The zone's plate: the swap wash, the re-split slab or the dock rail, one view re-framed rather than
    /// three mounted, because at most one of them is ever on screen.
    private let zone = UIView()
    /// The would-be divider, on the slab's inner edge. Mounted for the re-split zone alone.
    private let seam = UIView()
    /// The lifted pane's dashed border. A layer rather than a view's `borderWidth`, because UIKit borders
    /// cannot dash and this is the one stroke in the file that has to.
    private let lifted = CAShapeLayer()
    private let chip = PaneMoveGhostChipView()

    /// What the zone preview is currently drawn FOR, as a comparable key.
    ///
    /// The cross-fade hangs off this and not off the frames: within one zone the finger moves and nothing
    /// should animate at all, and across zones a frame animation would sweep a half-pane rectangle from
    /// one edge of the target to the other, which reads as something heavy being thrown. A short opacity
    /// snap on the CHANGE, and stillness otherwise.
    private var zoneKey: String?
    /// How much accent the zone's rim is currently spending — kept so a theme flip can re-resolve the
    /// border without having to be told which zone is on screen. A slab's rim is quieter than a whole
    /// area's, and re-painting it at full strength on an appearance change would silently promote it.
    private var zoneRimWash = 1.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        zone.alpha = 0
        zone.layer.cornerRadius = Slate.Metric.radiusCard
        addSubview(zone)

        seam.alpha = 0
        addSubview(seam)

        lifted.fillColor = nil
        lifted.lineWidth = Slate.DropPreview.slabRim
        // `[NSNumber]` is `CALayer`'s own signature and nothing this file chose: the rung stays a plain
        // array of points and is bridged at the ONE site that hands it to Core Animation.
        // swiftlint:disable:next legacy_objc_type
        lifted.lineDashPattern = Slate.DropPreview.liftedDash.map { NSNumber(value: Double($0)) }
        lifted.opacity = 0
        layer.addSublayer(lifted)

        addSubview(chip)
        paintInks()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.paintInks()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-draw for the live drag. Called on every finger frame, so everything in here is placement and
    /// nothing is construction.
    ///
    /// `frames` and `container` are the SOLVER's, handed down rather than looked up: the previews have to
    /// stand exactly where the panes do, and a view that re-derived either would be free to preview a
    /// landing the commit does not make.
    func show(
        drag: PaneMoveDrag,
        frames: [PaneID: CGRect],
        container: CGRect,
        sourceTitle: String?,
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Whole-layer visibility is taken instantly on the way IN and faded on the way out. A drag that
        // faded in would spend its first frames invisible, and those are exactly the frames in which the
        // user is deciding whether the strip took the touch at all.
        layer.opacity = 1
        applyLifted(frames[drag.source])
        CATransaction.commit()
        // The zone runs its own transactions — placement is de-animated and the cross-fade is not, and
        // only that method knows which of the two each statement is.
        applyZone(drag.zone, frames: frames, container: container)

        // The chip's WORDS and its MARK are ``PaneDropRegister``'s. It is asked for both at once and told
        // neither: a `switch` here over the register's own `Mark` would be the mark→artwork table spelled
        // a second time, in a renderer, where the cross-window panel that draws the very same capsule
        // cannot see it.
        chip.apply(
            symbol: PaneDropRegister.mark(for: drag.zone).symbol,
            label: PaneDropRegister.label(for: drag.zone, title: sourceTitle),
            cancels: drag.zone == .none,
        )
        chip.sizeToFit()
        chip.center = drag.location
    }

    /// The drag is over. The whole band goes at once rather than mark by mark — three separate fades over
    /// one event would read as the preview coming apart — and the key is dropped so the next drag's first
    /// frame is a fresh reveal rather than a continuation of this one's zone.
    func clear() {
        zoneKey = nil
        PaneFade.set(self, shown: false, curve: Slate.Motion.smallFade)
    }

    // MARK: The three marks

    /// One plate, framed by the zone. The three shapes differ in what they COVER and in how loudly they
    /// are outlined — a whole target, half of one, or the container's whole edge — and every one of those
    /// rectangles is computed on the floor.
    private func applyZone(_ dropZone: PaneDropZone, frames: [PaneID: CGRect], container: CGRect) {
        var plate: CGRect?
        var rim = Slate.DropPreview.wholeRim
        var wash = 1.0
        var bar: CGRect?
        // What the preview is FOR, which is not what it looks like: a swap and a dock can resolve to
        // the same rectangle at different moments of one drag, and a key built from geometry would call
        // that a continuation.
        var key: String?

        switch dropZone {
        case .none:
            break
        // SWAP: a wash over the WHOLE target — "this entire area exchanges with the one in the air".
        case let .swap(target):
            plate = frames[target]
            key = "swap-\(target)"
        // RE-SPLIT: the drop-side HALF of the target, plus a bright bar where the new divider would land,
        // so a column forming and a row forming are two different pictures rather than two captions.
        case let .resplit(target, edge):
            guard let rect = frames[target] else { break }
            let slab = PaneDropGeometry.slabRect(in: rect, edge: edge)
            plate = slab
            rim = Slate.DropPreview.slabRim
            wash = Slate.DropPreview.slabRimWash
            key = "resplit-\(target)-\(edge.rawValue)"
            let size = PaneDropGeometry.seamSize(slab, edge: edge)
            let centre = PaneDropGeometry.seamCenter(slab, edge: edge)
            bar = CGRect(
                x: centre.x - size.width / 2,
                y: centre.y - size.height / 2,
                width: size.width,
                height: size.height,
            )
        // DOCK: a rail down the container's whole edge — full span, tab-wide, and deliberately a different
        // silhouette from the per-pane half-slab it would otherwise be confused with.
        case let .dock(edge):
            plate = PaneDropGeometry.railRect(in: container, edge: edge)
            key = "dock-\(edge.rawValue)"
        }

        guard let plate else {
            zoneKey = nil
            PaneFade.set(zone, shown: false, curve: Slate.Motion.smallFade)
            PaneFade.set(seam, shown: false, curve: Slate.Motion.smallFade)
            return
        }

        let changed = key != zoneKey
        zoneKey = key
        zoneRimWash = wash

        // PLACEMENT, de-animated: within one zone the finger keeps moving and none of this may drift
        // after it. The opacity reset rides along in the same breath on a zone CHANGE, so the fade below
        // has a zero to start from.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zone.frame = plate
        zone.layer.borderWidth = rim
        if let bar {
            seam.frame = bar
            seam.layer.cornerRadius = min(bar.width, bar.height) / 2
        }
        if changed {
            zone.layer.opacity = 0
            seam.layer.opacity = 0
        }
        paintZoneRim()
        CATransaction.commit()

        // The one thing in this method that is meant to move. It is a no-op at rest: ``PaneFade`` returns
        // early when the opacity it is asked for is the opacity already there, so an unchanged zone
        // crossing sixty finger frames animates nothing at all.
        PaneFade.set(zone, shown: true, curve: Slate.Motion.smallFade)
        PaneFade.set(seam, shown: bar != nil, curve: Slate.Motion.smallFade)
    }

    /// The dashed border around the pane that was lifted. Drawn even when the zone resolves to nothing,
    /// because "you are holding this one" stays true for the whole drag.
    private func applyLifted(_ rect: CGRect?) {
        guard let rect else {
            lifted.opacity = 0
            return
        }
        lifted.opacity = 1
        lifted.frame = rect
        lifted.path = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: rect.size),
            cornerRadius: Slate.Metric.radiusCard,
        ).cgPath
    }

    private func paintInks() {
        zone.backgroundColor = Slate.Native.State.accentMuted
        seam.backgroundColor = Slate.Native.State.accent
        // A `CAShapeLayer` holds a resolved `CGColor` and cannot re-resolve a dynamic one for itself,
        // which is why every stroke here is re-taken against the CURRENT traits rather than assigned once.
        lifted.strokeColor = Slate.Native.State.accent
            .slateScalingAlpha(Slate.DropPreview.liftedWash)
            .resolvedColor(with: traitCollection).cgColor
        paintZoneRim()
    }

    /// The zone plate's border, at whatever dose the zone on screen asked for. Split out because the two
    /// callers arrive for different reasons: a new zone changes the dose, an appearance change changes the
    /// colour the dose is taken from, and neither knows the other's half.
    private func paintZoneRim() {
        zone.layer.borderColor = Slate.Native.State.accent
            .slateScalingAlpha(zoneRimWash)
            .resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - The chip pinned to the finger

/// The capsule that follows the drag and names its outcome.
///
/// The SAME capsule is drawn by the cross-window panel on the Mac, in another framework, and both can be
/// on screen inside one drag — so every number it is made of is ``Slate/DropChip``'s. That is not a
/// tidiness rule: a half-step of padding or a slightly different rim between the two reads as the chip
/// glitching, and nobody finds out until a user drags between them.
@MainActor
private final class PaneMoveGhostChipView: UIView {
    private let glyph = UIImageView()
    private let caption = UILabel()
    private var cancels = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.borderWidth = Slate.Metric.hairline

        glyph.contentMode = .center
        addSubview(glyph)

        caption.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        caption.numberOfLines = 1
        addSubview(caption)

        paintInks()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.paintInks()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func apply(symbol: SFSymbol, label: String, cancels: Bool) {
        glyph.image = UIImage(systemSymbol: symbol)
            .applyingSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: .semibold),
            )
        caption.text = label
        self.cancels = cancels
        paintInks()
    }

    /// Intrinsic width is the phrase's, so the capsule hugs its words on both sides — a fixed-width chip
    /// would centre a short label in a wide capsule and read as a control rather than as a caption.
    override func sizeThatFits(_: CGSize) -> CGSize {
        let mark = glyph.image?.size ?? .zero
        let words = caption.intrinsicContentSize
        return CGSize(
            width: mark.width + Slate.DropChip.glyphGap + words.width + Slate.DropChip.padH * 2,
            height: max(mark.height, words.height) + Slate.DropChip.padV * 2,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mark = glyph.image?.size ?? .zero
        glyph.frame = CGRect(
            x: Slate.DropChip.padH,
            y: (bounds.height - mark.height) / 2,
            width: mark.width,
            height: mark.height,
        )
        let wordsX = glyph.frame.maxX + Slate.DropChip.glyphGap
        caption.frame = CGRect(
            x: wordsX,
            y: Slate.DropChip.padV,
            width: max(0, bounds.width - wordsX - Slate.DropChip.padH),
            height: bounds.height - Slate.DropChip.padV * 2,
        )
        // A capsule is a corner radius of half the height, and it has to be re-taken on every pass
        // because the height follows the label's own metrics rather than a fixed control rung.
        layer.cornerRadius = bounds.height / 2
        layer.slateShadow(.ghost, in: traitCollection)
        CATransaction.commit()
    }

    /// The rim is the chip's only verdict: accent while a release would DO something, and the dimmed
    /// tertiary rung while it would not. ``Slate/DropChip/cancelRim`` is that dose, and it used to be a
    /// raw literal here — off the ladder by a twentieth, in the one place where being off it mattered
    /// least and cost most, since it was the single number keeping the two chips from being provably
    /// identical.
    private func paintInks() {
        backgroundColor = Slate.Native.Surface.face
        let ink = cancels ? Slate.Native.Text.tertiary : Slate.Native.Text.primary
        caption.textColor = ink
        glyph.tintColor = ink
        let rim = cancels
            ? Slate.Native.Text.tertiary.slateScalingAlpha(Slate.DropChip.cancelRim)
            : Slate.Native.State.accent
        layer.borderColor = rim.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
