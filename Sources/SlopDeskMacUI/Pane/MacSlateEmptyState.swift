// MacSlateEmptyState — the workspace empty-state voice (MERIDIAN C3), MAC HALF (docs/56 wave R, R12).
//
// One quiet composition for every "nothing here" the pane area can be in: a muted symbol, a short
// title, a one-line cause and — when the cause has one — the single next action. Never
// `ContentUnavailableView`, whose voice and metrics sit outside the Slate system.
//
// WHAT IT SAYS IS NOT HERE. The symbol name, the title, the caption and the action label all hang off
// ``PaneEmptyCause`` in `SlopDeskClientCore` (pinned by `PaneEmptyCopyTests`), which is where they
// descended to in R12 — they are `String`s, and a frameworkless table goes to the floor both renderers
// read instead of being pinned as a cross-renderer pair (docs/56 §3, P6). So this file and
// ``SlopDeskClientUI/SlateEmptyState`` are two DRAWINGS of one sentence, and the sentence cannot drift.
//
// At-rest = zero ornament (the standing bar): plain text on the island's face, no card, no shadow. The
// only chrome is the action's raised plate — which IS the action, not decoration.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacSlateEmptyState: NSView {
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let action: MacEmptyStateActionButton
    private let stack = NSStackView()

    /// What the action fires with. Held rather than closed over per cause, because the CAUSE is what
    /// decides the verb (Connect editor vs New Tab) and the cause changes under a live view.
    private var cause: PaneEmptyCause = .neverConnected

    /// Fires the current cause's single next action. The caller switches on the cause it is handed —
    /// this view never mints a command of its own.
    var onAction: (PaneEmptyCause) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        action = MacEmptyStateActionButton()
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(.neverConnected)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        glyph.contentTintColor = Slate.Native.Text.tertiary
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.display, weight: .ultraLight,
        )

        title.font = .systemFont(ofSize: Slate.Typeface.body, weight: .medium)
        title.textColor = Slate.Native.Text.primary
        title.alignment = .center

        caption.font = .systemFont(ofSize: Slate.Typeface.base)
        caption.textColor = Slate.Native.Text.secondary
        caption.alignment = .center
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 2

        action.onClick = { [weak self] in
            guard let self else { return }
            onAction(cause)
        }

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Slate.Metric.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [glyph, title, caption, action] { stack.addArrangedSubview(view) }
        // The two gaps that are NOT the base rhythm, spelled as the phone spells them: the symbol keeps
        // a step of air under it (`.padding(.bottom, space1)`) and the action stands a step off the
        // sentence it answers (`.padding(.top, space2)`). A verb pressed against its own explanation
        // reads as a fourth line of prose.
        stack.setCustomSpacing(Slate.Metric.space2 + Slate.Metric.space1, after: glyph)
        stack.setCustomSpacing(Slate.Metric.space2 * 2, after: caption)

        addSubview(stack)
        NSLayoutConstraint.activate([
            // Centred with `centerY`, NOT pinned top and bottom: a group pinned to both edges of a
            // surface that is 900pt tall one moment and 200 the next stretches its own spacing, and
            // this is a group.
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -Slate.Metric.space4 * 2,
            ),
            caption.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    /// Re-reads the cause. Idempotent — the canvas re-applies on every tracked pass, and a cause that
    /// did not change must not restage the view (the action button owns a tracking area).
    func apply(_ cause: PaneEmptyCause) {
        guard cause != self.cause || title.stringValue.isEmpty else { return }
        self.cause = cause
        glyph.image = NSImage(systemSymbolName: cause.symbolName, accessibilityDescription: nil)
        title.stringValue = cause.title
        caption.stringValue = cause.caption
        if let label = cause.actionLabel {
            action.title = label
            action.isHidden = false
        } else {
            // Link-down redials itself. HIDDEN rather than disabled: a greyed-out button still says
            // "there is something for you to press here", which is the opposite of the truth.
            action.isHidden = true
        }
        setAccessibilityLabel([cause.title, cause.caption].joined(separator: ". "))
    }
}

// MARK: - The action's plate

/// The empty state's one button: a label on the raised plate, hairline-ringed, at the control corner.
///
/// A bespoke `NSView` rather than a bordered `NSButton`, for the reason ``MacPanelPlateButton`` gives:
/// `NSButton`'s bezel draws its own material and its own corner, so a button made to look like the
/// design would be a button drawn twice. It is NOT that button, though — this plate carries the
/// workspace's own metrics (``Slate/Metric/heightBar``, reading-size type, a RIM) where the panel's is
/// a compact rimless chip, and the two surfaces are answerable to different rows in `DESIGN.md`.
@MainActor
final class MacEmptyStateActionButton: NSView {
    var onClick: () -> Void = {}

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            toolTip = newValue
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var hovering = false
    private var pressed = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline

        label.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        label.textColor = Slate.Native.Text.primary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightBar),
        ])
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    /// Re-resolved on every appearance change: a `CALayer` holds a flat `CGColor`, so a dynamic
    /// `NSColor` written into one stops following the appearance the moment it is stored.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: SlateNativeColor = hovering && !pressed
                ? Slate.Native.State.hover
                : Slate.Native.Surface.raised
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = Slate.Native.Line.subtle.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    override func mouseDown(with _: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    /// Fires on the UP, and only inside — a press dragged off the plate is a press taken back, the
    /// platform's own contract for every button on screen beside this one.
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    /// The fill crosses on the family's short curve — the phone spells the same beat as
    /// `.animation(Slate.Anim.smallFade, value: hover)`, and a plate that snapped between two greys
    /// under a moving pointer would read as a flicker rather than as a control lighting up.
    private func setHovering(_ inside: Bool) {
        guard hovering != inside else { return }
        hovering = inside
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            updateLayer()
        }
    }
}
