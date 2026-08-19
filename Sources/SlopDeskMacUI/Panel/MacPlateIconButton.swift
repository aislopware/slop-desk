// MacPlateIconButton — the hover-plate icon button, in AppKit: a borderless SF Symbol that grows a
// faint rounded plate under the pointer, and keeps a stronger one while whatever it turns on is on.
//
// It is the chrome's ONE button idiom, and it carries two rules that are easy to lose when a control
// is rebuilt:
//
//   • LATCHED IS INK AND WEIGHT, NEVER THE ACCENT (user-directed 2026-08-04). A blue glyph is a hue
//     carrying state, which is the pattern this app reversed twice; primary ink one weight up says the
//     same thing in the two channels that survive any theme, and reads as "on" rather than "special".
//   • A PRESS MOVES THE PLATE ONE RUNG toward what the click is about to do — a loose plate lights
//     toward "on", a latched one drops toward "off". Every verb on these plates acts on a remote
//     device, so the only other acknowledgement is that device changing a round trip later, and a key
//     that does not move under the pointer reads as one that missed the click.
//
// The SwiftUI original also carried a symbol BOUNCE on the acknowledgement. That effect is
// `symbolEffect`, which has no AppKit equivalent that does not amount to reimplementing it — so the
// Mac's plate spends the fill rung alone, which was always the load-bearing half (the bounce answers
// "a click arrived", the rung answers "and here is where it lands").

import AppKit
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacPlateIconButton: NSView {
    /// The glyph's name. Settable so a control whose verb flips (the panel's hide/show) can change
    /// what it draws without being rebuilt.
    var symbolName: String { didSet { repaint() } }
    /// A LATCHED state — the thing this button turns on is currently on. Distinct from hover, which is
    /// about the pointer: an active plate keeps its fill with the pointer elsewhere.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            fade()
        }
    }

    var onClick: () -> Void = {}

    private let glyph = NSImageView()
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    private let iconSize: CGFloat
    private let plate: CGFloat

    init(
        symbolName: String, iconSize: CGFloat = Slate.Metric.iconSize,
        plate: CGFloat = Slate.Metric.plate,
    ) {
        self.symbolName = symbolName
        self.iconSize = iconSize
        self.plate = plate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: plate),
            heightAnchor.constraint(equalToConstant: plate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }

    private func repaint() {
        layer?.backgroundColor = fill().cgColor
        // MEDIUM at rest — at 13pt an SF Symbol in the regular weight goes wispy against a light
        // theme's paper. SEMIBOLD is the one step above it, and it means latched.
        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: iconSize, weight: active ? .semibold : .medium,
                )
                .applying(NSImage.SymbolConfiguration(paletteColors: [
                    active ? Slate.Native.Text.primary : Slate.Native.Text.icon,
                ])),
            )
    }

    /// Loose: hover fills faintly, latched sits on the selection tint. XOR with the press, so pressing
    /// previews the latch state the click lands on.
    private func fill() -> NSColor {
        if active != pressed { return Slate.Native.State.selected }
        if !hovering, !pressed { return .clear }
        return Slate.Native.State.hover
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            needsDisplay = true
            updateLayer()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Hover + the click

    private func track() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        track()
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        fade()
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        fade()
    }

    override func mouseDown(with _: NSEvent) {
        pressed = true
        fade()
    }

    /// The verb fires on the RELEASE, and only inside the plate — a press dragged off it is a
    /// cancelled click, which is the contract every button on this platform keeps.
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        fade()
        guard inside else { return }
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
