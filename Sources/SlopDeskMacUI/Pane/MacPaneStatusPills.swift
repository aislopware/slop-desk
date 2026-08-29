// MacPaneStatusPills — the pane's status chips, in AppKit (docs/56 wave R, batch R2).
//
// The AppKit half of ``PaneStatusPillView``. ONE view over ``PaneStatusPill`` (`SlopDeskClientCore`),
// which says what each chip is CALLED, what VoiceOver reads, whether it carries an `×` and what kind
// of plate it stands on — `🔒 READ ONLY ×`, `🛡 SECURE INPUT`, `⚠ SYNC INPUT ×`.
//
// WHICH chips are up, and in what order, is ``PaneStatusPillPresentation/visible(_:)``'s — not this
// file's and not the leaf's. This view draws ONE chip; the top-trailing column that stacks them (with
// the vi-mode pill above and the find bar below) belongs to whatever mounts it, which is batch R9 for
// the terminal leaf and R10 for the video leaf — and R10 mounts a single `.readOnly` chip rather than
// a column at all, which is why there is no column type here.
//
// The design reference mock places these in a window TITLEBAR's top-right corner
// (`docs/ui-shell/screenshots/readonly-mode.png` and, later, `secure-input.png`). slopdesk has NO
// persistent titlebar — the window chrome is a hover-reveal strip and the pane is a flush,
// window-level surface — so the EQUIVALENT placement is the pane's top-trailing overlay region (the
// same place the ⌘F find bar floats).
//
// `Slate.*` tokens ONLY, in their native (NSColor/NSFont) spelling. The MARK is
// ``Slate/PaneStatusPill/symbol``'s (stage F batch P6) rather than a table on this side of the
// framework boundary: a fourth pill added below has to reach BOTH renderers, and a table either
// renderer owns is one the other cannot see at all.
//
// WHY A LAYER AND NOT `draw(_:)`. The chip is a filled rounded rectangle, an optional hairline and a
// cast — three CALayer properties. A `draw(_:)` override would re-derive the rounded rect path, and
// the shadow would then need a `shadowPath` kept in step with it by hand. `wantsUpdateLayer` also
// gives the appearance re-resolve for free: every rung below is a dynamic `NSColor`, and
// `updateLayer` runs again when the effective appearance changes.
//
// THE `×` IS ITS OWN VIEW AND OWNS AN `NSTrackingArea`. It has to: `hitTest` is not what drives a
// hover plate, and a rect-based tracking area is the only AppKit spelling of `.onHover`. ⚠️ Tracking
// areas keep firing under a tab that is only alpha-0 (docs/56 risk 3) — harmless HERE, because all a
// stale hover paints is an invisible plate on an invisible chip, but it is the reason this file does
// not hand a tracking area to anything larger.

import AppKit
import SFSafeSymbols // the mark's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // PaneStatusPill / PaneStatusPillFill / PaneStatusPillInk — decided below
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceModel

/// One pane status chip.
///
/// Faithful to `readonly-mode.png` and `secure-input.png`: the read-only chip is compact and SUBTLY
/// FILLED (it blends with the chrome rather than standing out) with a solid padlock and a
/// primary-tone label, then a LIGHTER `×`; the two mode chips are VIVID FILLED plates carrying a
/// white glyph and a white label, with no `×` on secure input.
///
/// `onDismiss` fires from the `×` and is ignored by a chip that has none. The leaf routes it:
/// read-only to ``TerminalViewModel/exitReadOnly()`` (whose `onReadOnlyChanged` hook converges the
/// store's `paneReadOnly` set, so the `×`, the View-menu item, the palette term and the sidebar lock
/// all land on one state) and sync input to ``WorkspaceStore/disarmSyncInput(for:)`` (which disarms
/// the WHOLE tab, so the chip leaves every sibling at once).
@MainActor
final class MacPaneStatusPillView: NSView {
    /// The chip this view draws. `let`: a chip whose state changed is a different chip, and the
    /// column that mounts them keys on the pill — so nothing ever needs to mutate one in place.
    let pill: PaneStatusPill

    private let onDismiss: () -> Void

    private let row = NSStackView()
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// Present exactly when ``PaneStatusPill/dismissHelp`` is — the pill answers whether the mode is
    /// one the user turns off from HERE, and secure input is deliberately not (see that property).
    private let close: MacPaneStatusPillCloseView?

    init(pill: PaneStatusPill, onDismiss: @escaping () -> Void = {}) {
        self.pill = pill
        self.onDismiss = onDismiss
        close = pill.dismissHelp.map { MacPaneStatusPillCloseView(help: $0, fill: pill.fill) }
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        // A small shadow lifts the chip off busy terminal output for legibility. `masksToBounds`
        // stays false or the cast is clipped away by the very plate casting it.
        layer?.masksToBounds = false
        layer?.shadowRadius = Slate.Elevation.chip.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.chip.y)
        layer?.shadowOpacity = 1

        glyph.imageScaling = .scaleNone
        label.isSelectable = false
        label.maximumNumberOfLines = 1
        // The word is a fixed caps constant, never elided: a chip that truncated to `SECURE INP…`
        // would be reporting a security state in a form the user has to guess at. It resists
        // compression instead, so a column too narrow for it overflows visibly rather than lying.
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The chip is ONE accessibility element carrying the shared copy — the glyph and the word are
        // two spellings of the same fact, and VoiceOver reading both would say it twice.
        glyph.setAccessibilityElement(false)
        label.setAccessibilityElement(false)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space2,
            bottom: Slate.Metric.space1, right: Slate.Metric.space2,
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(glyph)
        row.addArrangedSubview(label)
        if let close {
            close.onPress = { [weak self] in self?.onDismiss() }
            row.addArrangedSubview(close)
        }
        addSubview(row)
        NSLayoutConstraint.activate(row.slateEdges(of: self))

        // A GROUP rather than SwiftUI's combined element, and the difference is the `×`. `.combine`
        // folds a child button's action into one element; AppKit has no equivalent that keeps the
        // dismiss operable, so the chip is a labelled container and the `×` stays a button inside it
        // — the copy is read once, and the one thing on the chip you can DO is still reachable.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(pill.accessibilityLabel)
        setAccessibilityHelp(pill.accessibilityHint)

        paint()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // `effectiveAppearance` has to be the CURRENT one while a dynamic colour resolves, or every
        // rung answers for whatever appearance happened to be drawing last.
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func paint() {
        layer?.backgroundColor = plate.cgColor
        layer?.borderWidth = hairlineWidth
        layer?.borderColor = Slate.Native.Line.subtle.cgColor
        layer?.shadowColor = Slate.Native.State.shadow.cgColor

        let tone = ink
        glyph.image = NSImage(systemSymbolName: pill.symbol.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.small, weight: glyphWeight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tone])),
            )
        label.attributedStringValue = NSAttributedString(
            string: pill.label,
            attributes: [
                // The SYSTEM face, not the instrument one: this is a status word in the chrome's own
                // voice, not a readout of anything the terminal printed.
                .font: NSFont.systemFont(ofSize: Slate.Typeface.footnote, weight: labelWeight),
                .foregroundColor: tone,
                // The pill/badge rung of the caps tracking ladder — measured off the system
                // secure-input pill's own small-caps spacing, and applied ONLY to an all-caps label.
                .kern: Slate.Typeface.pillTracking,
            ],
        )
    }

    // MARK: - This renderer's ink ladder

    /// The chip's plate. The two vivid tones are ``Slate/Native/paneStatusPillFill(_:)``'s (docs/56
    /// batch 3) — theme-INDEPENDENT on purpose (the shipped themes have `info == accent`, so a
    /// palette-derived security badge would be invisible against the accent — `secure-input.png` is
    /// the green-accent Paper theme yet the pill is the same royal blue), and only a NAME can say
    /// that, which is why ``PaneStatusPillFill`` is a kind rather than a colour in the first place.
    private var plate: NSColor {
        switch pill.fill {
        case .chrome: Slate.Native.Surface.raised
        case let .fixed(ink): Slate.Native.paneStatusPillFill(ink)
        }
    }

    /// A chrome plate is DELINEATED by a hairline (it is only a shade off the chrome behind it); a
    /// vivid plate is not (the fill already is the boundary, and a border would only muddy it). A
    /// width of zero rather than a nil border colour, because `borderWidth` is the property that
    /// actually decides whether anything is drawn.
    private var hairlineWidth: CGFloat {
        switch pill.fill {
        case .chrome: Slate.Metric.hairline
        case .fixed: 0
        }
    }

    /// Label and glyph ink: the theme's primary tone on the chrome plate, white on a vivid one.
    ///
    /// White is reached as `SlateNativeColor.white` and not through a token, which is deliberate:
    /// ``Slate/Native`` leaves `Text/onAccent` out on purpose — it is pinned white in every
    /// appearance, so it is not a colour the platform has an opinion about.
    private var ink: NSColor {
        switch pill.fill {
        case .chrome: Slate.Native.Text.primary
        case .fixed: SlateNativeColor.white
        }
    }

    /// A vivid chip carries more weight than a chrome one — it is louder on purpose.
    private var glyphWeight: NSFont.Weight {
        switch pill.fill {
        case .chrome: .semibold
        case .fixed: .bold
        }
    }

    private var labelWeight: NSFont.Weight {
        switch pill.fill {
        case .chrome: .medium
        case .fixed: .semibold
        }
    }
}

// MARK: - The × plate

/// The `×` close glyph, with the tab row's subtle hover plate.
///
/// Its own view rather than a `NSButton`: the plate is a fill on a layer and the hover is a tracking
/// area, which is all a bordered-less button would have given anyway once its own drawing was turned
/// off — and this way the fill rung and the glyph rung are spelled where the reason for each is.
@MainActor
final class MacPaneStatusPillCloseView: NSView {
    var onPress: () -> Void = {}

    /// The glyph's ink, decided by the plate this `×` stands on and fixed for the chip's life. The
    /// `NSColor` is dynamic; only which ROLE was chosen is frozen here.
    private let ink: NSColor
    private let glyph = NSImageView()
    private var hovering = false
    private var tracking: NSTrackingArea?

    /// Takes the FILL rather than a colour: the rule below is about the plate this glyph stands on,
    /// and the chip builds its `×` before `super.init`, where it cannot yet ask itself anything.
    init(help: String, fill: PaneStatusPillFill) {
        // The `×` glyph's own ink: LIGHTER than the label on the chrome plate (per the screenshot),
        // but full white on a vivid one, where a secondary tone would vanish.
        ink =
            switch fill {
            case .chrome: Slate.Native.Text.secondary
            case .fixed: SlateNativeColor.white
            }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            // The plate is a RUNG (``Slate/Metric/glyphPlate``, stage F batch P6), not a literal —
            // it was one while three chips in this directory each spelled it.
            widthAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            heightAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // The tooltip IS the label: `dismissHelp` is already a verb phrase naming what the click
        // does ("Disable read-only"), which is what a button element is supposed to announce.
        setAccessibilityLabel(help)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func repaint() {
        // The SELECTION wash, not the hover fill: this is the same plate the tab row's own `×`
        // grows, and the two are compared by anyone who closes a tab and then dismisses a chip.
        layer?.backgroundColor = (hovering ? Slate.Native.State.selected : NSColor.clear).cgColor
        glyph.image = NSImage(systemSymbolName: SFSymbol.xmark.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.small, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
    }

    /// The plate FADES in rather than snapping. ``Slate/Motion/smallFade`` names this exact use ("the
    /// hover plate"), and it is the rung every other plate in the AppKit chrome spends
    /// (``MacPlateIconButton``) — a `×` that popped would be the one control in the window that does.
    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            needsDisplay = true
            updateLayer()
        }
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

    /// The verb fires on the RELEASE, and only inside the plate — a press dragged off it is a
    /// cancelled click, which is the contract every button on this platform keeps. It matters more
    /// here than on a toolbar plate: what this one cancels is a MODE (a lock, a whole tab's mirrored
    /// input), and an accidental dismiss is not something the chip can offer to undo.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
