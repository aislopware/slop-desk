// MacStatusMark — the rail's trailing status mark, drawn by AppKit.
//
// The mark is the one thing on this rail that MOVES, and the movement is a function of the wall
// clock: ``AgentSpinner/phase(at:seed:)`` integrates a wandering tempo in closed form so a re-render
// lands the hole mid-lap instead of snapping it back. That maths is shared and stays shared — this
// file draws it, it does not decide it. Same for WHICH mark a row wears
// (``StatusPresentation/statusDot(working:badge:agentIdle:agentFinish:)`` → a ``StatusDotStyle``) and
// for every geometry number (``StatusDot``): one 14pt column, one ring diameter, one dot pitch.
//
// ⚠️ EVERY MAC SURFACE THAT WEARS A MARK NOW DRAWS IT HERE. The navigator's rows
// (``MacSidebarRowView``) and the collapsed band's tab chips (`MacTabChipView`) crossed first; the
// titlebar band's aggregate rollup (``MacRailStatusMarksView``) was the last holdout and crossed
// with docs/56 stage D's cheapest kind-1 surface, which is what deleted `RailStatusRollup`'s
// `SlopDeskClientUI` import.
//
// The mark is still drawn twice — but the second renderer is the PHONE's. ``StatusDotView`` lives in
// `SlopDeskClientUI`, whose navigator is the iOS half, and it STAYS there: that is the
// ``FindModePill`` arrangement on exactly the terms it is allowed on, ONE value deciding the mark and
// its ink and two frameworks painting it. What is no longer true is the thing that made it debt — no
// surface is painted by both halves any more, so a hue or a silhouette can no longer be corrected in
// one renderer and left stale in the other on the same screen.
//
// ⚠️ `import SwiftUI` IS GONE, AND IT WAS NEVER DRAWING ANYTHING. This file has been AppKit since it
// was written; the import bought exactly two BRIDGES out of the token layer's SwiftUI spelling — an
// `NSColor(style.ink)` because ``StatusDotStyle/ink`` was a `Color`, and a `.cgPath` because
// `SVGPath` returned a `Path`. Both spellings were deleted from `SlopDeskSlate` in the same pass:
// `ink` is a ``SlateNativeColor`` and the vector door is ``SVGPath/cgPath(_:viewBox:in:)``. Two
// conversions vanished with the import rather than moving.
//
// The display link runs only while a spinner is actually on screen — a resting rail costs no frames.

import AppKit
import QuartzCore // the spinner's display link
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

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
        let ink = style.ink
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

    /// A system symbol at otty's own configuration for it — the artwork is Apple's, so this mounts the
    /// EXACT drawing rather than a redraw of it. The ink rides a PALETTE configuration rather than a
    /// template tint: a template only takes the ink a cell hands it, and this view has no cell.
    ///
    /// The weight is ``StatusDot/symbolWeight`` itself, not a hand-copy of it: on macOS
    /// `NSImage.SymbolConfiguration(pointSize:weight:)` takes an `NSFont.Weight`, which is exactly what
    /// the token already is, so there is no seam here to keep in step. (UIKit's twin has one — its
    /// configuration asks for a distinct `UIImage.SymbolWeight` — and says so at its own call site.)
    private func drawSymbol(_ mark: StatusMark, ink: NSColor) {
        guard let system = mark.systemSymbol,
              let image = NSImage(
                  systemSymbolName: system.symbol.rawValue, accessibilityDescription: nil,
              ),
              let drawn = image.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: system.size, weight: StatusDot.symbolWeight)
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
    /// replaced did. The geometry is ``StatusDot/ringDotFrame(_:in:)``'s (docs/56 batch 3), one floor
    /// down and shared with the phone's `DottedRing`; this only turns those frames into ovals. The
    /// ring is drawn CENTRED in `bounds` (the mark's 14×14 column) rather than in a `ringDiameter`-
    /// sized rect, which is why the frame function's diameter scaling is a no-op here — this view is
    /// always mounted at its native size.
    private func drawRing(ink: NSColor) {
        let box = CGRect(
            x: bounds.midX - StatusDot.ringDiameter / 2, y: bounds.midY - StatusDot.ringDiameter / 2,
            width: StatusDot.ringDiameter, height: StatusDot.ringDiameter,
        )
        let path = NSBezierPath()
        for index in 0..<StatusDot.ringDotCount {
            path.appendOval(in: StatusDot.ringDotFrame(index, in: box))
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
        SlateVectorDraw.stroke(icon, in: rect, ink: ink.cgColor, into: context)
    }

    /// The THINKING mark: a braille cell with every dot lit and ONE hole running round it. The hole's
    /// position is ``AgentSpinner/phase(at:seed:)`` and each dot's ink is ``AgentSpinner/lit(_:hole:)``
    /// of its distance from it, so the gap SLIDES rather than hopping between eight positions.
    private func drawSpinner(ink: NSColor, frozen: Bool) {
        let phase = frozen ? 0 : AgentSpinner.phase(at: Date(), seed: seed)
        let hole = phase * Double(BrailleCell.dotCount)
        let box = CGSize(width: StatusDot.footprint, height: StatusDot.footprint)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // `BrailleCell.position` answers in a TOP-DOWN box (the geometry's own convention); this view
        // is bottom-up, so the dots step the other way from the box's TOP edge — which in this space
        // is the larger y. The mirror is a sign, not a second copy of the cell.
        SlateVectorDraw.brailleCell(
            into: context, ink: ink.cgColor, hole: hole, box: box,
            anchor: CGPoint(x: bounds.midX - box.width / 2, y: bounds.midY + box.height / 2),
            step: -1, zoom: 1,
        )
    }
}
