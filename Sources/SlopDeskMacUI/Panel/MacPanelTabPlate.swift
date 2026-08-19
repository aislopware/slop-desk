// MacPanelTabPlate — one of the RIGHT panel's four tabs: a mark AND its name on a plate. In AppKit.
//
// BOTH, on every tab, is the point. The strip spent two rounds with marks alone on the unselected tabs
// and read ragged both times (user-reported 2026-08-04): a folder outline, a narrow solid logo, a wide
// solid dome and a wide screen have no optical mass in common, and equalising their ink to a 2.5pt
// band did not help, because ink height was never what the eye was comparing. A word beside each mark
// settles it without touching the marks at all — the labels are the same height by construction, and
// they push the marks far enough apart that no two of them are read against each other. Marks alone
// were then tried and the strip lost too much (user-directed 2026-08-05).
//
// So the mark identifies and the word names, and a tab that has room shows both. When the panel is
// dragged narrow it gives the words up a rung at a time rather than truncating — the ladder is
// ``PanelTabs/labelling(available:cell:gap:named:selected:)``, one floor down, and `showsLabel` is how
// a rung of it is asked for.
//
// ⚠️ LAID OUT BY HAND, and NOTHING HERE IS A TURNED VIEW. The rail runs these four down a column one
// plate wide, and the tab still stands in that column's footprint — what turns is the row of content
// INSIDE it, by a layer transform about the tab's own centre, with each mark turning back out in its
// own `draw(_:)`. Turning the view itself was tried and fails twice over: `frameCenterRotation` pivots
// a layer-backed view about its layer's anchor point (the frame's CORNER, not its centre) and threw
// every rail tab clean out of the rail, and even had it pivoted correctly the tab's hit area would
// have stayed a 104pt bar lying across a 24pt rail, overlapping both neighbours. Hand layout is what
// makes ONE plate serve both axes; the footprint stays honest on either.
//
// The SELECTED plate is NOT drawn here. It is one travelling `CALayer` owned by the group, for the same
// reason the sidebar's and the tab strip's are: the selection MOVES between tabs, and a fill each tab
// paints for itself can only appear and disappear. Two animation redesigns of that appearing and
// disappearing were rejected — round 1's opacity fades read as cheap, round 2's width morph as stuttery
// — and travel is neither: nothing fades and nothing changes width. All this leaf paints is the HOVER
// tint, which answers the pointer rather than the selection and is a separate channel.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacPanelTabPlate: NSView {
    let tab: PanelTabReading
    var onClick: () -> Void = {}

    /// The mark and the word, in the box the plate would occupy if it were NEVER turned. It is this
    /// view — and not the tab — that the rail turns; see ``plateRotation``.
    private let content = MacPanelTabContent()
    private let mark: NSView & MacPanelMark
    private let label = NSTextField(labelWithString: "")
    private var selected = false
    private var showsLabel = true
    private var hovering = false
    private var tracking: NSTrackingArea?

    /// How far this tab's CONTENT is turned, in degrees, clockwise-negative.
    ///
    /// The mark takes the same angle back out. A word on its side is still read — the eye tilts and
    /// the letters keep their order — but a GLYPH on its side is a different glyph: a rotated `folder`
    /// reads as a shape rather than as a folder, and Apple's own optical grid stops meaning anything
    /// (user-directed 2026-08-09). So the rail turns the words and the marks stay upright.
    ///
    /// ⚠️ THE VIEW ITSELF NEVER TURNS, and `frameCenterRotation` is not what does this. Two reasons,
    /// one measured and one structural. Measured: on a LAYER-BACKED view AppKit turns the layer about
    /// its anchor point — which is `(0, 0)`, the frame's corner — so a quarter turn threw each rail tab
    /// a whole tab-length out of the rail and the render came back empty. Structural: a turned view's
    /// frame is still its unturned box, so its HIT AREA would be a 104pt bar lying across a 24pt rail,
    /// overlapping both neighbours. Turning only the content leaves the tab standing in the footprint
    /// it actually occupies, which is the rectangle the pointer, the tracking area and the travelling
    /// plate all want.
    ///
    /// Fixed at init because the MARK bakes the counter-turn into what it draws — see ``MacPanelMark``.
    let plateRotation: CGFloat

    init(tab: PanelTabReading, plateRotation: CGFloat = 0) {
        self.tab = tab
        self.plateRotation = plateRotation
        // The mark stands UPRIGHT inside a turned tab, so it is handed the turn it has to undo.
        mark =
            switch tab.mark {
            case let .symbol(name): MacSymbolMark(symbolName: name, turn: -plateRotation)
            case .android: MacAndroidMark(turn: -plateRotation)
            }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.islandRadiusCompact
        layer?.cornerCurve = .continuous

        label.stringValue = tab.label
        label.maximumNumberOfLines = 1
        // ⚠️ OUT OF THE ENGINE, both of them, and this is the line that makes hand layout WORK inside
        // an Auto Layout tree. A subview left at `translates = true` gets an
        // `NSAutoresizingMaskLayoutConstraint` per edge, minted from whatever frame it had when the
        // engine first engaged the plate — and every frame this view writes in `layout()` is then
        // solved straight back out. Measured on the rail: the Android mark carried `width == 0` and
        // `height == 0` constraints for its whole life and photographed as nothing at all, while the
        // three symbol marks happened to be captured after their images had sized them and looked
        // fine. With `translates = false` and NO constraints of their own, the engine has nothing to
        // say about either child and the frame written here is the frame that stands.
        content.translatesAutoresizingMaskIntoConstraints = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mark)
        content.addSubview(label)
        addSubview(content)

        toolTip = tab.help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.label)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: The two states

    func apply(selected: Bool, showsLabel: Bool) {
        self.selected = selected
        self.showsLabel = showsLabel
        needsLayout = true
        needsDisplay = true
        updateLayer()
    }

    // MARK: Measure

    /// What a bare cell puts around its mark to reach the plate's square. The marks differ in width, so
    /// this is derived from the WIDEST of them — the Android head at ``Slate/Metric/androidMark`` — and
    /// the narrower symbols simply sit centred in the same cell.
    private static let bareInset = (Slate.Metric.plate - Slate.Metric.androidMark) / 2

    /// A named tab is `[collar][mark][gap][label][collar]`; a bare one is the SQUARE cell the action
    /// plates at the other end of the strip occupy — NOT a plate hugging its mark, because the marks
    /// are 10 to 17 points across and hugging gives four different widths and a row of ragged gaps.
    var idealWidth: CGFloat {
        guard showsLabel else { return Slate.Metric.plate }
        return Slate.Metric.space2 + markSize.width + Slate.Metric.space1
            + textWidth + Slate.Metric.space2
    }

    /// What this tab's LABEL costs the strip beyond its bare cell — the ladder's `named` input. Asked of
    /// the view because only the renderer can measure its own type.
    var labelCost: CGFloat {
        Slate.Metric.space2 + markSize.width + Slate.Metric.space1
            + textWidth + Slate.Metric.space2 - Slate.Metric.plate
    }

    /// ⚠️ `fittingSize`, NOT `intrinsicContentSize`. A label's intrinsic width is its GLYPHS; its
    /// fitting width is what the cell needs to lay them out, and measured here the two differ by a
    /// flat 4pt on every one of the four words (Desktop: 44 against 48). Framed to the intrinsic
    /// width, a label whose last glyph carries no right side bearing loses it — "Desktop" drew as
    /// "Deskto" with the `p` half-eaten at every width the strip had room for the word at all, while
    /// "Files" and "Emulators" looked fine and hid the bug. Ceiled on top, so a fractional measure
    /// cannot land back on the same edge.
    private var textWidth: CGFloat { label.fittingSize.width.rounded(.up) }

    /// The mark's CELL, which each kind reports for itself — already swapped when the rail has turned
    /// this tab, since a 19×9 glyph standing upright in a turned tab occupies 9×19.
    private var markSize: CGSize { mark.intrinsicContentSize }

    override var intrinsicContentSize: NSSize {
        NSSize(width: idealWidth, height: Slate.Metric.plate)
    }

    override func layout() {
        super.layout()
        // The unturned box: the tab's own footprint across, and the footprint with its sides SWAPPED
        // when the rail has turned it — centred either way, because the turn is about the centre.
        let box = plateRotation == 0
            ? bounds
            : CGRect(
                x: bounds.midX - bounds.height / 2, y: bounds.midY - bounds.width / 2,
                width: bounds.height, height: bounds.width,
            )
        // ⚠️ THE SIZE IS DECLARED, not merely assigned. Auto Layout manages every view in the window,
        // and for one with no intrinsic size of its own it solves the size from the autoresizing
        // constraints it minted when it first engaged — which for a view built at `.zero` and framed
        // by hand afterwards means `width == 0`, re-imposed after every `layout()`. Measured: this
        // view's frame write was solved straight back out and the whole rail photographed empty. The
        // mark and the label survive the same treatment only because both HAVE an intrinsic size.
        content.box = box.size
        content.frame = box
        content.wantsLayer = true
        content.layer?.transform = Self.turn(plateRotation, about: box.size)

        label.isHidden = !showsLabel
        let size = markSize
        let markX = showsLabel ? Slate.Metric.space2 : (box.width - size.width) / 2
        mark.frame = CGRect(
            x: markX, y: (box.height - size.height) / 2,
            width: size.width, height: size.height,
        )
        guard showsLabel else { return }
        let text = label.intrinsicContentSize
        label.frame = CGRect(
            x: mark.frame.maxX + Slate.Metric.space1, y: (box.height - text.height) / 2,
            width: textWidth, height: text.height,
        )
    }

    /// A turn of `degrees` about the CENTRE of a `size`-sized layer.
    ///
    /// ⚠️ The two translations are the whole point. A layer-backed `NSView`'s layer has its anchor
    /// point at `(0, 0)`, so a bare `CATransform3DMakeRotation` pivots on the corner and throws the
    /// content clean out of its own box — which is exactly how the rail's tabs disappeared. Walk the
    /// centre to the origin, turn, walk it back.
    private static func turn(_ degrees: CGFloat, about size: CGSize) -> CATransform3D {
        guard degrees != 0 else { return CATransform3DIdentity }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        var transform = CATransform3DMakeTranslation(centre.x, centre.y, 0)
        transform = CATransform3DRotate(transform, degrees * .pi / 180, 0, 0, 1)
        return CATransform3DTranslate(transform, -centre.x, -centre.y, 0)
    }

    // MARK: Paint

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }

    private func repaint() {
        // The SELECTED fill belongs to the travelling plate — see this file's header. Hover is this
        // leaf's, and only while nothing is selected here: a hover tint under the plate is invisible
        // and would only pay for a repaint.
        layer?.backgroundColor = hovering && !selected
            ? Slate.Native.State.hover.cgColor
            : NSColor.clear.cgColor
        let ink = selected ? Slate.Native.Text.primary : Slate.Native.Text.icon
        // MEDIUM when selected, REGULAR when not — weight and ink carrying the state together, the same
        // pair every other latched control in this chrome uses.
        label.font = .systemFont(
            ofSize: Slate.Typeface.footnote, weight: selected ? .medium : .regular,
        )
        label.textColor = ink
        mark.paint(ink)
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

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            needsDisplay = true
            updateLayer()
        }
    }

    override func mouseDown(with _: NSEvent) { onClick() }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

/// The turning half of a tab. It exists to carry a SIZE Auto Layout will respect — see the note in
/// ``MacPanelTabPlate/layout()``.
@MainActor
private final class MacPanelTabContent: NSView {
    var box: CGSize = .zero {
        didSet {
            guard box != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: box.width, height: box.height) }
}

// MARK: - The two kinds of mark

/// A tab's mark, in the ink the tab is currently wearing.
///
/// ⚠️ A mark that stands in a TURNED tab bakes the counter-turn into what it DRAWS, and reports the
/// cell that drawing occupies. It does not carry a layer transform, and the reason is measured: the
/// mark sits under Auto Layout, every pass re-syncs its layer geometry from the solved frame, and that
/// sync resets `transform` — a counter-turn written in `layout()` and even re-written after every
/// repaint was identity again by the time anything was photographed, and the rail came out with four
/// glyphs lying on their sides. A rotation inside `draw(_:)` cannot be undone by the layout engine.
@MainActor
protocol MacPanelMark: NSView {
    func paint(_ ink: NSColor)
}

/// A symbol on Apple's optical grid, at the STRIP's icon measure (``Slate/Metric/iconSize``) — the one
/// the action plates at the other end of the same strip use, and NOT the label's type size. A glyph and
/// a word are not the same kind of thing, and sizing both from `footnote` had the tabs drawing at 11
/// while the reload button beside them drew at 13.
@MainActor
private final class MacSymbolMark: NSView, MacPanelMark {
    private let symbolName: String
    private let turn: CGFloat
    private var image: NSImage?
    private var ink: NSColor = Slate.Native.Text.icon

    init(symbolName: String, turn: CGFloat) {
        self.symbolName = symbolName
        self.turn = turn
        super.init(frame: .zero)
        setAccessibilityElement(false)
        paint(ink)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The glyph's own box, with its sides SWAPPED when this mark stands in a turned tab.
    override var intrinsicContentSize: NSSize {
        let size = image?.size ?? NSSize(width: Slate.Metric.iconSize, height: Slate.Metric.iconSize)
        return turn == 0 ? size : NSSize(width: size.height, height: size.width)
    }

    func paint(_ ink: NSColor) {
        self.ink = ink
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Metric.iconSize, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: turn * .pi / 180)
        image.draw(
            in: NSRect(
                x: -image.size.width / 2, y: -image.size.height / 2,
                width: image.size.width, height: image.size.height,
            ),
        )
        context.restoreGState()
    }
}

/// The Android head, drawn — see ``AndroidMarkPath``, which owns every proportion. This view owns only
/// the fact that AppKit draws y-UP where the path is authored y-down, and the counter-turn.
@MainActor
private final class MacAndroidMark: NSView, MacPanelMark {
    private let turn: CGFloat
    private var ink: NSColor = Slate.Native.Text.icon

    init(turn: CGFloat) {
        self.turn = turn
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Square, so the turn leaves the cell alone — the ONE mark in the app carrying a measure of its
    /// own, because it is a drawn path with no optical grid behind it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Slate.Metric.androidMark, height: Slate.Metric.androidMark)
    }

    func paint(_ ink: NSColor) {
        self.ink = ink
        needsDisplay = true
    }

    /// ⚠️ FLIPPED, and that is the whole reason this override exists. Every angle in ``AndroidMarkPath``
    /// is stated in the y-down space `CGPath` and SwiftUI's `Path` share, where 270° is up; drawn in
    /// AppKit's default y-up view the dome would open downward and the antennae would grow through it.
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The counter-turn, about the cell's centre. Negated against the symbol mark's: this view
        // draws y-down, where a positive angle turns the other way.
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: -turn * .pi / 180)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.setFillColor(ink.cgColor)
        context.setStrokeColor(ink.cgColor)
        // The antennae go down FIRST and as their own path: the head is filled even-odd, and an antenna
        // crossing the dome's rim inside that one path would subtract a notch from it exactly where the
        // two meet.
        context.setLineWidth(AndroidMarkPath.antennaLineWidth(in: bounds))
        context.setLineCap(.round)
        context.addPath(AndroidMarkPath.antennae(in: bounds))
        context.strokePath()
        context.addPath(AndroidMarkPath.head(in: bounds))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }
}
