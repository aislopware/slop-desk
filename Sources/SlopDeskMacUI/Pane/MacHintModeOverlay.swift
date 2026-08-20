// MacHintModeOverlay — the Vimium-style Hint Mode overlay, in AppKit (docs/56 wave R, batch R4).
//
// A DECORATION layered OVER the terminal surface, never a content branch (the libghostty-freeze
// guardrail): while the pane model has an armed intent (``TerminalViewModel/hintMode``) it DIMS the
// surface so the labels pop, draws a yellow 2-letter badge at each detected target, and shows a
// `HINTS · <intent> · ×` badge top-trailing — the `hint-mode.png` chrome, floated in the pane because
// slopdesk has no titlebar, exactly like the vi-mode and read-only chips beside it.
//
// KEYSTROKES ARE NOT THIS VIEW'S. The renderer's `keyDown` routes them to
// ``TerminalViewModel/handleHintKey(_:)`` while hint mode is up (NOT to the PTY); that dims the
// non-matching labels on the first letter and runs the action on the second, with no Enter. This
// overlay only RENDERS the pure state it leaves behind. Nothing here taps the event stream, and
// nothing here may: a second reader of the same key is how a chord ends up handled twice.
//
// EVERY DECISION AND EVERY WORD IS ``HintPresentation``'s (`SlopDeskClientCore`) — the arm predicate,
// the per-letter fade rule, the uppercasing, the dim predicate over
// ``HintLabelAssigner/filter(typed:labels:)`` and the five strings. WHICH letters a label gets, in
// what order, and which spans are eligible at all are one floor further down
// (``HintLabelAssigner``), assigned ONCE per session by ``TerminalViewModel/beginHint(_:)`` and
// stable for its life. What is left here is the ink and the placement, which is the whole of what an
// AppKit half can differ in.
//
// ⚠️ THIS VIEW IS FLIPPED, AND THAT IS LOAD-BEARING. ``TerminalCellMetrics`` reports points in a
// TOP-LEFT-origin space (the convention the surface's own `sendMousePos` uses). AppKit's default is
// bottom-left, so an unflipped overlay would place every badge mirrored about the pane's horizontal
// midline — plausible-looking labels pointing at the wrong words, which is the one failure mode the
// honest-ceiling rule below exists to rule out.
//
// Honest ceiling: a headless / placeholder surface does not conform to
// ``TerminalViewportSnapshotting`` (the real surface hangs without a window server — CLAUDE.md rule
// #6), so `cellMetrics()` is absent and the overlay draws NOTHING. Labels are ABSENT, never wrong.
// The actuation itself is the leaf's (``TerminalViewModel/onHintConfirmed``).
//
// `Slate.*` tokens for the chrome; the badge is a FIXED yellow plate with BLACK text — the hint-mode
// spec's "yellow background / black text", theme-independent so it reads over any terminal
// background, the secure-input-pill rationale. Black and white are the two rungs ``Slate/Native``
// deliberately does NOT carry (see its header): they are not colours the platform has an opinion
// about, so `NSColor.black` reaches ``Slate/Text/onWarn`` without a token standing in the way.

import AppKit
import SFSafeSymbols // the mark's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // HintPresentation — the arm predicate, the fade rule and the five strings
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskTerminal
import SlopDeskWorkspaceCore

/// The hint chrome's two PINNED values, spelled once for the file that draws them all.
///
/// ``Slate/Native`` deliberately carries no rung for black or white — see its header: they are not
/// colours the platform has an opinion about, so they are reached directly and ``Slate/Text/onWarn``
/// is the SwiftUI view of this same value. Both the label badges and the mode badge stand on the
/// SAME pinned yellow, so both read their ink from here rather than one of them reaching into the
/// other's type for it.
@MainActor
private enum HintPlate {
    /// Ink ON the pinned yellow plate — theme-independent, so it reads over any terminal background
    /// (the hint-mode spec, the secure-input-pill rationale).
    static let ink = NSColor.black
    /// The plate itself.
    static var fill: NSColor { Slate.Native.Status.warn }
}

@MainActor
final class MacHintModeOverlay: NSView {
    /// The pane's terminal model — read for the OBSERVABLE armed intent (`hintMode`) and typed prefix
    /// (`hintTyped`), and dereferenced (non-reactively) for its `surface` viewport geometry at draw
    /// time. The targets and the labels are `@ObservationIgnored` on purpose: they are set ONCE per
    /// session, and re-detecting per keystroke would re-shuffle every label under the user's eye.
    private let model: TerminalViewModel

    private let dim = MacHintDimPlate(frame: .zero)
    private let badge: MacHintModeBadge
    private var marks: [MacHintLabelBadge] = []

    /// Whether the overlay is up. It gates ``hitTest(_:)`` as well as the drawing, because the dim
    /// plate is deliberately OPAQUE to the pointer while hint mode is live (a stray click must not
    /// reach the terminal under it) and must be equally deliberately transparent when it is not.
    private var armed = false
    /// The session this view is currently drawn for. The labels are stable for a session, so a
    /// keystroke re-inks the mounted badges instead of rebuilding them — a rebuild would drop and
    /// recreate every tracking area and every layer in the pane on each letter.
    private var session: Session?

    /// What makes two drawings the same drawing. The METRICS are in it because a font-size change or
    /// a resize moves every badge without changing a single label.
    private struct Session: Equatable {
        let intent: HintIntent
        let labels: [String]
        let metrics: TerminalCellMetrics
    }

    init(model: TerminalViewModel) {
        self.model = model
        badge = MacHintModeBadge(onExit: { [weak model] in model?.cancelHintMode() })
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// See the file header: ``TerminalCellMetrics`` is top-left-origin, so the overlay it feeds must
    /// be too.
    override var isFlipped: Bool { true }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // Every child is placed from CELL GEOMETRY rather than from constraints — a badge's position
        // is arithmetic over `(row, colStart)` that Auto Layout has no way to express — so the
        // subviews stay autoresizing-framed and this view does the placing in `layout()`.
        dim.onCancel = { [weak model] in model?.cancelHintMode() }
        addSubview(dim)
        addSubview(badge)
        isHidden = true
    }

    // MARK: The live read

    /// Re-read the two observable properties and redraw, re-arming for the next change.
    ///
    /// The geometry read sits in `apply`, OUTSIDE the tracking closure, for the reason the SwiftUI
    /// half puts it inside the active branch: `surface` is `@ObservationIgnored` and a weak reference
    /// to a live renderer, so making it part of the dependency would register nothing and cost a
    /// retain cycle's worth of confusion for it.
    private func follow() {
        var intent: HintIntent?
        var typed = ""
        withObservationTracking {
            intent = model.hintMode
            typed = model.hintTyped
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        apply(intent: intent, typed: typed)
    }

    private func apply(intent: HintIntent?, typed: String) {
        let snapshot = model.surface as? TerminalViewportSnapshotting
        guard let intent, let metrics = snapshot?.cellMetrics(),
              HintPresentation.isArmed(
                  intent: intent, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
              )
        else {
            retire()
            return
        }
        let next = Session(intent: intent, labels: model.hintLabels, metrics: metrics)
        if next != session {
            session = next
            mount(next)
        }
        armed = true
        isHidden = false
        badge.apply(intent: intent, typed: typed)
        // The typed prefix admits a SET of labels, asked once per keystroke rather than once per
        // badge: `matchedLabels` builds it, and every badge then answers about itself in O(1).
        let matched = HintPresentation.matchedLabels(typed: typed, labels: next.labels)
        for mark in marks {
            mark.apply(typed: typed, dimmed: HintPresentation.dimmed(label: mark.label, matched: matched))
        }
        needsLayout = true
    }

    /// Build one badge per target whose first cell is actually ON the visible grid.
    ///
    /// ⚠️ CLAMPED, not merely offset: a target whose `colStart` lands off-screen-right (a
    /// soft-wrap-shifted span) is SKIPPED rather than anchored in the void, which is
    /// ``TerminalCellMetrics/clampedRect(row:colStart:colEnd:)``'s whole reason for existing. A badge
    /// in the margin points at nothing while still claiming a letter.
    private func mount(_ session: Session) {
        for mark in marks { mark.removeFromSuperview() }
        marks = []
        for (target, label) in zip(model.hintTargets, session.labels) {
            guard let rect = session.metrics.clampedRect(
                row: target.row, colStart: target.colStart, colEnd: target.colEnd,
            ) else { continue }
            let mark = MacHintLabelBadge(label: label, anchor: rect.origin)
            mark.onConfirm = { [weak model] in model?.confirmHintTarget(target) }
            marks.append(mark)
            // BELOW the mode badge. A target in the pane's top-trailing corner would otherwise be
            // drawn over the chip that says which mode you are in and how to leave it — the one
            // thing on screen that must never be occluded by the thing it is describing.
            addSubview(mark, positioned: .below, relativeTo: badge)
        }
    }

    /// Take the whole overlay down.
    ///
    /// `isHidden`, not an alpha: a hidden view is out of the pointer's way, out of the drawing pass
    /// AND out of tracking-area consideration together, which is what the SwiftUI half's `if` gets
    /// for free. The badges go with it rather than lingering invisibly — a mounted `×` keeps an
    /// `NSTrackingArea` alive under a pane that is only faded out (docs/56 risk 3).
    private func retire() {
        guard armed || !marks.isEmpty else { return }
        armed = false
        isHidden = true
        session = nil
        for mark in marks { mark.removeFromSuperview() }
        marks = []
    }

    // MARK: Placement

    override func layout() {
        super.layout()
        dim.frame = bounds
        let badgeSize = badge.fittingSize
        badge.frame = NSRect(
            x: bounds.maxX - badgeSize.width - Slate.Metric.space2, y: Slate.Metric.space2,
            width: badgeSize.width, height: badgeSize.height,
        )
        for mark in marks {
            let size = mark.fittingSize
            mark.frame = NSRect(origin: mark.anchor, size: size)
        }
    }

    /// Transparent to the pointer while the mode is DOWN. Up, it is deliberately not: the dim plate
    /// swallows stray clicks that would otherwise land in the terminal mid-hint, and a click on it
    /// cancels the mode — the same escape the `×` and Esc offer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        armed ? super.hitTest(point) : nil
    }

    /// Belt-and-suspenders Escape cancel. The primary route is the renderer's `keyDown` →
    /// `cancelHintMode()` once the terminal is first responder; this is the net for an Esc that lands
    /// in the OVERLAY's chain instead — a click on the `×` or on the dim plate leaves focus here.
    ///
    /// `cancelOperation(_:)` is AppKit's spelling of what the phone spells ``View/slateCancelKey(perform:)``: AppKit walks Esc (and ⌘.) up the responder chain, so this fires from
    /// anywhere at or below the overlay without anyone installing a monitor. A local event monitor
    /// here would be a second reader of a key the renderer already consumes, and is banned in this
    /// directory for exactly that.
    override func cancelOperation(_: Any?) {
        model.cancelHintMode()
    }
}

// MARK: - The dim plate

/// The scrim under the labels, and the mode's largest cancel target.
///
/// It is the SAME token the modal overlays dim with. Two jobs, and the second is the one that is easy
/// to lose in a port: it BLOCKS clicks to the terminal while hint mode is up, so a mis-aimed click
/// cancels the mode instead of moving the cursor in whatever is running.
@MainActor
private final class MacHintDimPlate: NSView {
    var onCancel: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func paint() {
        layer?.backgroundColor = Slate.Native.State.shadow.cgColor
    }

    override func mouseDown(with _: NSEvent) {
        onCancel()
    }
}

// MARK: - One label badge

/// A single yellow 2-letter hint badge standing on its target's first cell.
///
/// The already-typed first letter is drawn faded so the user sees which key is next; a label the
/// typed prefix has ruled out is dimmed as a WHOLE PLATE rather than removed, because a badge that
/// vanished would let the eye read the target as gone and force the remaining field to be re-scanned
/// after every keystroke.
@MainActor
private final class MacHintLabelBadge: NSView {
    /// ⚠️ 14 is UNNAMED on the floor — the badge's minimum height, deliberately UNDER the keycap's 18
    /// because a badge stands ON the grid rather than beside a label. It is the SECOND spelling: the
    /// SwiftUI half carries the same literal with the same ⚠️. Proposed `Slate.Metric.hintBadge`.
    private static let minHeight: CGFloat = 14
    /// ⚠️ 0.2 is UNNAMED on the floor — the ruled-out badge's opacity, a rung BELOW
    /// ``Slate/Opacity/dim`` (0.35) because this dims a whole PLATE rather than ink on one. Second
    /// spelling, same ⚠️ as the SwiftUI half. Proposed `Slate.Opacity.dimmedPlate`.
    private static let ruledOut: CGFloat = 0.2

    let label: String
    /// The badge's top-left in the overlay's (flipped, top-left-origin) space — its target's first
    /// cell, straight out of ``TerminalCellMetrics/clampedRect(row:colStart:colEnd:)``.
    let anchor: CGPoint

    var onConfirm: () -> Void = {}

    private let text = NSTextField(labelWithString: "")

    init(label: String, anchor: CGPoint) {
        self.label = label
        self.anchor = anchor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline

        text.isSelectable = false
        text.maximumNumberOfLines = 1
        text.lineBreakMode = .byClipping
        text.setAccessibilityElement(false)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space1),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space1),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),
            heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(HintPresentation.labelAccessibility(label))
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-ink for the current typed prefix. The plate does not move and the label does not change —
    /// only which letters are faded, and whether the whole badge is still in the running.
    func apply(typed: String, dimmed: Bool) {
        text.attributedStringValue = Self.letters(label: label, typed: typed)
        alphaValue = dimmed ? Self.ruledOut : 1
    }

    /// The 2 uppercase letters, already-typed ones faded (the progress cue), the rest solid black.
    /// WHICH letters are faded, and that the label is uppercased at all, are ``HintPresentation``'s —
    /// spelled as `offset < typed.count` there precisely because re-deriving it per renderer is a
    /// place a half could fade the wrong letter and still look plausible (on the very common case,
    /// nothing typed yet, every spelling agrees).
    private static func letters(label: String, typed: String) -> NSAttributedString {
        let run = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: Slate.Typeface.small, weight: .bold)
        for (offset, character) in HintPresentation.displayLabel(label).enumerated() {
            let faded = HintPresentation.isFaded(offset: offset, typed: typed)
            run.append(NSAttributedString(
                string: String(character),
                attributes: [
                    .font: font,
                    .foregroundColor: faded
                        ? HintPlate.ink.withAlphaComponent(Slate.Opacity.dim)
                        : HintPlate.ink,
                ],
            ))
        }
        return run
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    private func paint() {
        layer?.backgroundColor = HintPlate.fill.cgColor
        // A thin dark hairline so the yellow plate reads on a light background too.
        layer?.borderColor = HintPlate.ink.withAlphaComponent(Slate.Opacity.dim).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Clicking a badge resolves its target directly, through the SAME
    /// ``TerminalViewModel/confirmHintTarget(_:)`` seam a two-key resolve fires. It is unconditional
    /// in the source — written for the phone's soft keyboard, where typing two keys with the overlay
    /// up is awkward — and it costs a Mac user nothing to have the thing under the pointer be
    /// clickable.
    override func mouseDown(with _: NSEvent) {
        onConfirm()
    }

    override func accessibilityPerformPress() -> Bool {
        onConfirm()
        return true
    }
}

// MARK: - The mode badge

/// The `HINTS` mode badge — the `hint-mode.png` titlebar chip, floated in the pane's top-trailing
/// region since slopdesk has no titlebar. Shows the active intent, the keys typed so far, and an `×`
/// that leaves the mode.
@MainActor
private final class MacHintModeBadge: NSView {
    private let onExit: () -> Void

    private let row = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let intentLabel = NSTextField(labelWithString: "")
    /// The typed prefix. Hidden rather than removed when nothing has been typed — an arranged
    /// subview that is hidden leaves the stack's layout, which is the AppKit spelling of the SwiftUI
    /// half's `if !typed.isEmpty`.
    private let typedLabel = NSTextField(labelWithString: "")
    private let close = MacHintBadgeCloseView(frame: .zero)

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowRadius = Slate.Elevation.chip.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.chip.y)
        layer?.shadowOpacity = 1

        title.attributedStringValue = NSAttributedString(
            string: HintPresentation.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: Slate.Typeface.footnote, weight: .bold),
                .foregroundColor: HintPlate.ink,
                .kern: Slate.Typeface.pillTracking,
            ],
        )
        typedLabel.font = .monospacedSystemFont(ofSize: Slate.Typeface.footnote, weight: .bold)
        typedLabel.textColor = HintPlate.ink

        for text in [title, intentLabel, typedLabel] {
            text.isSelectable = false
            text.maximumNumberOfLines = 1
            // The intent word and the typed keys are the two facts the badge exists to report; a chip
            // narrow enough to elide `REVEAL` would be naming the verb the user has to guess at.
            text.lineBreakMode = .byClipping
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.setAccessibilityElement(false)
        }

        close.onPress = { [weak self] in self?.onExit() }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space2,
            bottom: Slate.Metric.space1, right: Slate.Metric.space2,
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(title)
        row.addArrangedSubview(intentLabel)
        row.addArrangedSubview(typedLabel)
        row.addArrangedSubview(close)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A GROUP, not SwiftUI's combined element, for the reason the status chip gives: `.combine`
        // folds a child button's action into one element and AppKit has no equivalent that keeps the
        // dismiss operable, so the badge is a labelled container with a real `×` button inside it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityHelp(HintPresentation.badgeAccessibilityHint)
        paint()
    }

    func apply(intent: HintIntent, typed: String) {
        intentLabel.attributedStringValue = NSAttributedString(
            string: intent.badgeLabel,
            attributes: [
                .font: NSFont.systemFont(ofSize: Slate.Typeface.small, weight: .semibold),
                .foregroundColor: HintPlate.ink
                    .withAlphaComponent(Slate.Opacity.muted),
                .kern: Slate.Typeface.pillTracking,
            ],
        )
        typedLabel.stringValue = HintPresentation.displayLabel(typed)
        typedLabel.isHidden = typed.isEmpty
        setAccessibilityLabel(HintPresentation.badgeAccessibilityLabel(intent))
        needsLayout = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func paint() {
        layer?.backgroundColor = HintPlate.fill.cgColor
        layer?.shadowColor = Slate.Native.State.shadow.cgColor
    }
}

// MARK: - The badge's × plate

/// The `×` that leaves hint mode — the same seam Esc and the dim-plate click fire.
///
/// NOT ``MacPaneStatusPillCloseView``, and the difference is the plate it stands on. That `×` grows
/// the SELECTION wash on hover, which is a tint of the brand accent; here it would land on a PINNED
/// yellow plate the accent has no relationship to at all. So this one acknowledges the pointer the
/// way the rest of the badge does — by going to full black from the muted rung — and the square it
/// takes is still ``Slate/Metric/glyphPlate``, because a mark that is a different size on this chip
/// than on the one above it reads as a different control.
@MainActor
private final class MacHintBadgeCloseView: NSView {
    var onPress: () -> Void = {}

    private let glyph = NSImageView()
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            // ``Slate/Metric/glyphPlate`` (stage F batch P6) — the ONE square every `×` on a pane chip
            // takes, and the hit area as much as the drawing.
            widthAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            heightAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        toolTip = HintPresentation.exitHelp
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // The tooltip IS the label: `exitHelp` already names the action and the key that does it.
        setAccessibilityLabel(HintPresentation.exitHelp)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func repaint() {
        glyph.image = NSImage(systemSymbolName: SFSymbol.xmark.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.small, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [
                        hovering
                            ? HintPlate.ink
                            : HintPlate.ink.withAlphaComponent(Slate.Opacity.muted),
                    ])),
            )
    }

    /// The glyph BRIGHTENS rather than snapping. ``Slate/Motion/smallFade`` names this exact use, and
    /// it is the rung every other hover in the AppKit chrome spends.
    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            repaint()
        }
    }

    // MARK: Hover + the click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
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
    /// cancelled click, which is the contract every button on this platform keeps.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
