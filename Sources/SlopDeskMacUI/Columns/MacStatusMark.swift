// MacStatusMark — the rail's trailing status mark, drawn by AppKit.
//
// The mark is the one thing on this rail that MOVES, and the movement is a function of the wall
// clock: ``AgentSpinner/phase(at:seed:)`` integrates a wandering tempo in closed form so a re-render
// lands the hole mid-lap instead of snapping it back. That maths is shared and stays shared — this
// file draws it, it does not decide it. Same for WHICH mark a row wears
// (``StatusPresentation/statusDot(working:badge:agentIdle:agentFinish:)`` → a ``StatusDotStyle``) and
// for every geometry number (``StatusDot``): one 14pt column, one ring diameter, one dot pitch.
//
// ⚠️ It is drawn TWICE while stage D runs — here in AppKit for the navigator's rows, and in SwiftUI
// (``StatusDotView``) for the collapsed-sidebar tab strip and the band's rollup, which are still
// hosted. That is the ``FindModePill`` arrangement and it is allowed on exactly the same terms: ONE
// value decides the mark and its ink, two frameworks paint it. The SwiftUI half dies with the strip.
//
// The display link runs only while a spinner is actually on screen — a resting rail costs no frames.

import AppKit
import QuartzCore // the spinner's display link
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SwiftUI // `SVGPath` returns a `Path`; its `cgPath` is what the hand is stroked from

/// One resolved mark in the rail's fixed 14pt column. `style == nil` draws nothing and the column
/// still holds its width, so a row that gains a mark never shifts the label beside it.
@MainActor
final class MacStatusMarkView: NSView {
    var style: StatusDotStyle? {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
            syncTicker()
        }
    }

    /// Where in the shared wander this mount sits — rolled once and held for the view's lifetime
    /// (``StatusDot/tempoSeedSpan``). Every mark obeys the same tempo law; the seed is only an offset
    /// into it, so two panes are never hurrying and dwelling in step.
    private let seed = Double.random(in: 0..<StatusDot.tempoSeedSpan)
    private var link: NSObject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: StatusDot.footprint),
            heightAnchor.constraint(equalToConstant: StatusDot.footprint),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTicker()
    }

    /// The spinner's clock: a display link while a RUNNING spinner is mounted in a window, nothing
    /// otherwise. Reduce Motion freezes it here rather than in the drawing, so an accessibility
    /// freeze and the render rig's pinned still are the same one parameter (phase 0).
    private func syncTicker() {
        let wants = window != nil && style?.mark == .working && style?.frozen == false
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wants, link == nil {
            let displayLink = displayLink(target: self, selector: #selector(tick))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else if !wants, let running = link as? CADisplayLink {
            running.invalidate()
            link = nil
        }
    }

    @objc
    private func tick() { needsDisplay = true }

    override func draw(_: NSRect) {
        guard let style else { return }
        let ink = NSColor(style.ink)
        switch style.mark {
        case .working:
            drawSpinner(ink: ink, frozen: style.frozen)
        case .agentRing:
            drawRing(ink: ink)
        case .awaiting:
            drawHand(ink: ink)
        case .agentFinish:
            drawSymbol(style.mark, ink: ink)
        }
    }

    /// A system symbol at otty's own configuration for it — the artwork is Apple's, so this is the
    /// EXACT drawing the SwiftUI half mounts rather than a redraw of it. The ink rides a PALETTE
    /// configuration rather than a template tint: a template only takes the ink a cell hands it, and
    /// this view has no cell.
    private func drawSymbol(_ mark: StatusMark, ink: NSColor) {
        guard let system = mark.systemSymbol,
              let image = NSImage(
                  systemSymbolName: system.symbol.rawValue, accessibilityDescription: nil,
              ),
              let drawn = image.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: system.size, weight: .medium)
                      .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
              )
        else { return }
        let size = drawn.size
        drawn.draw(in: NSRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height,
        ))
    }

    /// The agent-presence ring — ``StatusDot/ringDotCount`` dots spaced evenly round a circle, the
    /// first at 12 o'clock, each spilling half its width outside the circle exactly as the stroke it
    /// replaced did.
    private func drawRing(ink: NSColor) {
        let side = StatusDot.ringDiameter
        let radius = side / 2
        let dot = StatusDot.ringDotDiameter
        let path = NSBezierPath()
        for index in 0..<StatusDot.ringDotCount {
            let turn = 2 * Double.pi * Double(index) / Double(StatusDot.ringDotCount) - .pi / 2
            let centre = CGPoint(
                x: bounds.midX + radius * CGFloat(cos(turn)),
                y: bounds.midY + radius * CGFloat(sin(turn)),
            )
            path.appendOval(in: CGRect(
                x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot,
            ))
        }
        ink.setFill()
        path.fill()
    }

    /// otty's awaiting badge — lucide `hand`, stroked from the SAME path data the SwiftUI half
    /// draws (``OttyIcon/hand``), scaled out of its 24-unit viewBox.
    private func drawHand(ink: NSColor) {
        let icon = OttyIcon.hand
        let side = StatusDot.handSide
        let rect = NSRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side,
        )
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = side / icon.viewBox
        context.saveGState()
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(icon.strokeWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for outline in icon.outlines {
            context.addPath(SVGPath.path(outline, viewBox: icon.viewBox, in: rect).cgPath)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The THINKING mark: a braille cell with every dot lit and ONE hole running round it. The hole's
    /// position is ``AgentSpinner/phase(at:seed:)`` and each dot's ink is ``AgentSpinner/lit(_:hole:)``
    /// of its distance from it, so the gap SLIDES rather than hopping between eight positions.
    private func drawSpinner(ink: NSColor, frozen: Bool) {
        let phase = frozen ? 0 : AgentSpinner.phase(at: Date(), seed: seed)
        let hole = phase * Double(BrailleCell.dotCount)
        let side = StatusDot.dotDiameter
        let box = CGSize(width: StatusDot.footprint, height: StatusDot.footprint)
        for index in 0..<BrailleCell.dotCount {
            // `BrailleCell.position` answers in a TOP-DOWN box (the SwiftUI convention it was
            // written for); this view is bottom-up, so the y is mirrored inside the same box rather
            // than the cell's geometry being restated.
            let point = BrailleCell.position(of: index, in: box, zoom: 1)
            let centre = CGPoint(
                x: bounds.midX - box.width / 2 + point.x,
                y: bounds.midY + box.height / 2 - point.y,
            )
            ink.withAlphaComponent(AgentSpinner.lit(index, hole: hole)).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side,
            )).fill()
        }
    }
}
