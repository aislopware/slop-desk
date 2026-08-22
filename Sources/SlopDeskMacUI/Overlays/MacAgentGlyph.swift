// MacAgentGlyph — ONE pane's agent state, in AppKit: the status glyph and the braille cell that is
// its one moving reading.
//
// This is the first DESIGN-SYSTEM leaf to cross for docs/56 stage D rather than a whole surface, and
// it crosses on the terms ``Slate/Native`` set: what may be twinned is a LOOKUP, never a decision.
// Everything this file decides was already decided one floor down before it existed —
// ``AgentReadout`` maps a status to a reading and an ink, ``Slate/Native/agentInk(_:)`` resolves the
// ink, and the spinner's whole cadence (``AgentSpinner/phase(at:seed:)``, ``AgentSpinner/lit(_:hole:)``,
// ``BrailleCell/position(of:in:zoom:)``) is called out of the shared design system rather than
// rewritten here. Two renderers, one mark: a pane thinking in the sidebar and the same pane thinking
// in a peek card are the same hole at the same point of the same lap, because both read the same
// wall clock through the same integral.
//
// What is genuinely different is HOW the frames arrive. SwiftUI's `TimelineView(.animation)` schedules
// at the display's own refresh rate; the AppKit half asks the view's own `CADisplayLink` for the same
// thing, which is the same clock reached through the other framework's door.

import AppKit
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

// MARK: - The glyph

/// The agent status instrument, in a fixed ``AgentReadout/glyphBox`` square: a single character in
/// the instrument face for the three settled readings, and the drawn braille cell for the one that
/// moves.
///
/// The characters are the terminal's own dialect — `·` for a resting prompt, `?` for a question
/// waiting, `●` for an unread finish — exactly what the phone's ``StatusGlyph`` prints, because the
/// chrome's status voice IS the pane's voice on both platforms.
@MainActor
final class MacAgentGlyphView: NSView {
    private let character = NSTextField(labelWithString: "")
    private let spinner = MacAgentSpinnerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        character.alignment = .center
        character.isSelectable = false
        for view in [character, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let box = CGFloat(AgentReadout.glyphBox)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: box),
            heightAnchor.constraint(equalToConstant: box),
            character.centerXAnchor.constraint(equalTo: centerXAnchor),
            character.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-cuts the glyph for one pane's state.
    func show(reading: AgentReading, ink: AgentInk) {
        let tint = Slate.Native.agentInk(ink)
        spinner.isHidden = reading != .working
        character.isHidden = reading == .working
        spinner.tint = tint
        switch reading {
        case .resting: relabel("·", weight: .regular, tint: tint)
        case .awaiting: relabel("?", weight: .bold, tint: tint)
        case .done: relabel("●", weight: .regular, tint: tint)
        // The one reading that is not typed. It used to be a typed pulse on both surfaces, and the
        // rail and the header then said the same thing two different ways.
        case .working: break
        }
    }

    private func relabel(_ text: String, weight: NSFont.Weight, tint: NSColor) {
        character.stringValue = text
        character.font = Slate.Typeface.instrumentNative(Slate.Typeface.body, weight: weight)
        character.textColor = tint
    }
}

// MARK: - The one mark that moves

/// The thinking agent's braille cell: eight dots lit, one hole running clockwise round them.
///
/// FLIPPED, and that is the whole of what porting the geometry took. ``BrailleCell/position(of:in:zoom:)``
/// numbers its rows top-down because SwiftUI's coordinate space does; an unflipped `NSView` grows `y`
/// upward, so the identical walk would turn ANTICLOCKWISE — against every other spinner on the
/// machine, which is the exact fault the walk's own direction was reversed on hardware to fix.
@MainActor
final class MacAgentSpinnerView: NSView {
    /// The lit dots' ink. The hole is this same ink at ``StatusDot/holeFloor``.
    var tint: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    /// Where in the shared wander this mount sits. Every mark obeys one tempo law and each rolls its
    /// own offset into it, so two panes thinking at once are never at the same point of the same
    /// swell — without it the whole app would speed up and slow down in lockstep, which reads as the
    /// application hitching rather than as agents thinking.
    private let seed = Double.random(in: 0..<StatusDot.tempoSeedSpan)
    private var link: CADisplayLink?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let box = StatusDot.footprint
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: box),
            heightAnchor.constraint(equalToConstant: box),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Runs only while the mark is actually on screen, and never under Reduce Motion.
    ///
    /// A frozen cell is still a distinct silhouette — a lit block with one dot missing, which no
    /// other mark in this vocabulary resembles — so the state survives the freeze and only the
    /// movement is lost.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        needsDisplay = true
        guard window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let link = displayLink(target: self, selector: #selector(advance))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc
    private func advance() {
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        // Frozen at the head of the lap when the link is not running — the same still the render rig
        // photographs, so what a snapshot shows IS what Reduce Motion ships.
        let phase = link == nil ? 0 : AgentSpinner.phase(at: Date(), seed: seed)
        let hole = phase * Double(BrailleCell.dotCount)
        let side = StatusDot.dotDiameter
        // ⚠️ `fillEllipse` rather than `NSBezierPath(ovalIn:).fill()`: this loop runs on a display
        // link, so a path object per dot is EIGHT heap allocations (each with its own backing
        // `CGPath`) per frame per glyph, thrown away before the next tick. Measured in a scratch
        // `swiftc -O` harness drawing the same eight dots: 28.6 µs/frame with the paths, 22.5 µs
        // without — a fifth of the frame, for objects nothing reads. The INK still goes through
        // `withAlphaComponent`/`setFill` on purpose: a `setFillColor(red:green:blue:alpha:)` would
        // buy the rest of the gap and change the colour space the dot is filled in.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for index in 0..<BrailleCell.dotCount {
            let lit = AgentSpinner.lit(index, hole: hole)
            guard lit > 0 else { continue }
            let centre = BrailleCell.position(of: index, in: bounds.size, zoom: 1)
            tint.withAlphaComponent(lit).setFill()
            context.fillEllipse(in: CGRect(
                x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side,
            ))
        }
    }
}
