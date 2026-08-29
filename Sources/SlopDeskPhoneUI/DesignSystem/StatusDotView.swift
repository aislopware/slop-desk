// StatusDotView — the PHONE's renderers of the shared status mark.
//
// WHAT a mark is (``StatusDot``'s geometry, ``StatusMark``'s silhouette set, ``StatusDotStyle``'s
// resolved pair, ``AgentSpinner``'s wandering tempo and ``BrailleCell``'s walk) is `SlopDeskSlate`,
// below both renderers. What is here is one of the two: `SlopDeskMacUI` draws the same values as
// `NSView`s (`MacStatusMarkView`, `MacAgentSpinnerView` — docs/56 stage D), so a state edge cannot
// mean one thing in the rail and another in a hosted card. See `SlateStatusMark.swift` for every
// design note behind the numbers.
//
// These two are transliterations of the Mac's pair, on purpose and nearly line for line, because those
// already resolved every question this drawing asks. The ONE difference deletes code rather than adding
// it: `BrailleCell` and `StatusDot.ringDotFrame` answer in a TOP-DOWN box, which is UIKit's own space,
// so the y-mirror the AppKit twin carries in two places is simply absent here.

#if os(iOS)
import QuartzCore // the spinners' display link
import SFSafeSymbols
import SlopDeskSlate
import UIKit

/// One resolved mark in the fixed ``StatusDot/footprint`` column. `style == nil` draws nothing and the
/// column still holds its width, so a row that gains a mark never shifts the label beside it.
///
/// AX-hidden: the row title's accessibility value already speaks the same state, so the mark never
/// double-announces.
@MainActor
final class SlateStatusMarkView: UIView {
    var style: StatusDotStyle? {
        didSet {
            guard style != oldValue else { return }
            setNeedsDisplay()
            syncTicker()
        }
    }

    /// Where in the shared wander this mount sits — rolled once and held for the view's lifetime
    /// (``StatusDot/tempoSeedSpan``). Every mark obeys the same tempo law; the seed is only an offset
    /// into it, so two panes are never hurrying and dwelling in step.
    private let seed = Double.random(in: 0..<StatusDot.tempoSeedSpan)
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // Transparent: the mark is INK on whatever row it sits in, and an opaque backing would paint
        // the row's fill a second time at a tone the row did not choose.
        backgroundColor = .clear
        isOpaque = false
        // AX-hidden: the row title's accessibility value already speaks this state, so the mark never
        // double-announces.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    /// ⚠️ THE DISPLAY LINK'S WHOLE LIFETIME, and the reason `phone-display-links-are-invalidated`
    /// exists. A `CADisplayLink` retains its target STRONGLY and the run loop retains the link, so a
    /// view that starts one and is then removed is not deallocated — it is a live object being ticked
    /// at 120 Hz forever, drawing into a layer nobody composites. `didMoveToWindow` is the one edge
    /// that sees both directions (a `nil` window is a removal), which is why the start and the stop
    /// are the same function rather than a pair someone has to keep matched.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncTicker()
    }

    /// The spinner's clock: a display link while a RUNNING spinner is mounted in a window, nothing
    /// otherwise — a resting navigator costs no frames. Reduce Motion freezes it HERE rather than in
    /// the drawing, so an accessibility freeze and the render rig's pinned still are the same one
    /// parameter (phase 0) and can never become two different drawings of "not moving".
    private func syncTicker() {
        let wants = window != nil && style?.mark == .working && style?.frozen == false
            && !UIAccessibility.isReduceMotionEnabled
        if wants, link == nil {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else if !wants {
            link?.invalidate()
            link = nil
        }
    }

    @objc
    private func tick() { setNeedsDisplay() }

    override func draw(_: CGRect) {
        guard let style else { return }
        let ink = style.ink
        switch style.mark {
        case .working: drawSpinner(ink: ink, frozen: style.frozen)
        case .agentRing: drawRing(ink: ink)
        case .awaiting: drawHand(ink: ink)
        case .agentFinish: drawSymbol(style.mark, ink: ink)
        }
    }

    /// A system symbol at otty's own configuration for it — the artwork is Apple's, so this mounts the
    /// EXACT drawing rather than a redraw of it.
    ///
    /// ⚠️ `.medium` IS ``StatusDot/symbolWeight``, spelled again, and only on THIS side: the token is a
    /// `UIFont.Weight` while `UIImage.SymbolConfiguration(pointSize:weight:)` asks for
    /// `UIImage.SymbolWeight`, a third enum with no conversion. So the phone names its own value and the
    /// two must be kept in step by eye. (AppKit's twin takes an `NSFont.Weight` and has no such seam.)
    /// The INK rides the image rather than a tint: this view has no cell to hand a template one.
    private func drawSymbol(_ mark: StatusMark, ink: UIColor) {
        guard let system = mark.systemSymbol,
              let image = UIImage(
                  systemName: system.symbol.rawValue,
                  withConfiguration: UIImage.SymbolConfiguration(
                      pointSize: system.size, weight: .medium,
                  ),
              )?.withTintColor(ink, renderingMode: .alwaysOriginal)
        else { return }
        let size = image.size
        image.draw(in: CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height,
        ))
    }

    /// The agent-presence ring — ``StatusDot/ringDotCount`` dots spaced evenly round a circle, the
    /// first at 12 o'clock. The geometry is ``StatusDot/ringDotFrame(_:in:)``'s, shared with both other
    /// renderers; this only turns those frames into ovals.
    private func drawRing(ink: UIColor) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let box = CGRect(
            x: bounds.midX - StatusDot.ringDiameter / 2, y: bounds.midY - StatusDot.ringDiameter / 2,
            width: StatusDot.ringDiameter, height: StatusDot.ringDiameter,
        )
        ink.setFill()
        for index in 0..<StatusDot.ringDotCount {
            context.fillEllipse(in: StatusDot.ringDotFrame(index, in: box))
        }
    }

    /// otty's awaiting badge — lucide `hand`, stroked from the SAME path data both other renderers
    /// draw (``OttyIcon/hand``), scaled out of its 24-unit viewBox.
    private func drawHand(ink: UIColor) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let side = StatusDot.handSide
        SlateVectorDraw.stroke(
            OttyIcon.hand,
            in: CGRect(
                x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side,
                height: side,
            ),
            ink: ink.cgColor, into: context,
        )
    }

    /// The THINKING mark: a braille cell with every dot lit and ONE hole running round it. The hole's
    /// position is ``AgentSpinner/phase(at:seed:)`` and each dot's ink is ``AgentSpinner/lit(_:hole:)``
    /// of its distance from it, so the gap SLIDES rather than hopping between eight positions.
    private func drawSpinner(ink: UIColor, frozen: Bool) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let phase = frozen ? 0 : AgentSpinner.phase(at: Date(), seed: seed)
        SlateVectorDraw.brailleCell(
            into: context, ink: ink.cgColor, hole: phase * Double(BrailleCell.dotCount),
            box: CGSize(width: StatusDot.footprint, height: StatusDot.footprint),
            anchor: CGPoint(
                x: bounds.midX - StatusDot.footprint / 2, y: bounds.midY - StatusDot.footprint / 2,
            ),
            step: 1, zoom: 1,
        )
    }
}

/// The THINKING mark on its own, for the surfaces that mount a spinner without a whole status column
/// around it. Its cadence is ``AgentSpinner``'s: this view only puts the lit dots where
/// ``BrailleCell/position(of:in:zoom:)`` says and inks them by ``AgentSpinner/lit(_:hole:)``.
///
/// ⚠️ Reduce Motion freezes it — a frozen cell is still a distinct silhouette, so the state is never
/// lost, only the movement.
@MainActor
final class SlateAgentSpinnerView: UIView {
    /// The lit dots' ink. The hole is this same ink taken down to ``StatusDot/holeFloor``.
    var tint: UIColor = .label {
        didSet { setNeedsDisplay() }
    }

    /// Multiplies the whole mark — the render rig's way of magnifying it without resampling.
    var zoom: CGFloat = 1 {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// Hold the hole at ONE point of its lap instead of running it — the render rig's only way to
    /// photograph a moving mark, and the same still Reduce Motion asks for.
    var pinnedPhase: Double? {
        didSet { syncTicker() }
    }

    private let seed = Double.random(in: 0..<StatusDot.tempoSeedSpan)
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom)
    }

    /// See ``SlateStatusMarkView/didMoveToWindow()`` for why the start and the stop are one function.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncTicker()
    }

    private func syncTicker() {
        setNeedsDisplay()
        let wants = window != nil && pinnedPhase == nil && !UIAccessibility.isReduceMotionEnabled
        if wants, link == nil {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else if !wants {
            link?.invalidate()
            link = nil
        }
    }

    @objc
    private func tick() { setNeedsDisplay() }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // Frozen at the head of the lap when the link is not running — the same still the render rig
        // photographs, so what a snapshot shows IS what Reduce Motion ships.
        let phase = pinnedPhase ?? (link == nil ? 0 : AgentSpinner.phase(at: Date(), seed: seed))
        SlateVectorDraw.brailleCell(
            into: context, ink: tint.cgColor, hole: phase * Double(BrailleCell.dotCount),
            box: CGSize(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom),
            anchor: .zero, step: 1, zoom: zoom,
        )
    }
}
#endif
