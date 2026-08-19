// MacPanelEmptyStates — the RIGHT panel's three wordless-until-something-happens surfaces, in AppKit
// (docs/56 stage D, increment 51): the centred empty state, the centred spinner, and the open gate.
//
// All three are the SAME anatomy — a dim glyph, one primary line, one secondary line, centred in the
// whole surface — because the panel has one empty-state voice (MERIDIAN C3) and seven situations that
// speak in it. The gate adds a button and nothing else; that is what makes it the same surface rather
// than a fourth one.
//
// What each says is ``CodePanelPresentation``'s, one floor down and shared with the phone. What is
// here is the drawing: which `NSFont`, which rung of the text ladder, and the fact that a centred
// stack in AppKit is a stack pinned to a centre rather than a `frame(maxWidth:maxHeight:)`.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

/// The centred empty state: dim glyph, title, detail.
///
/// The DETAIL is selectable on both halves. It is the one line a reader may need to act on — a
/// provisioning command, most of the time — and a command you cannot select is a command you have to
/// retype.
@MainActor
final class MacPanelEmptyStateView: NSView {
    init(_ reading: PanelEmptyState) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(
            image: NSImage(systemSymbolName: reading.systemImage, accessibilityDescription: nil)
                ?? NSImage(),
        )
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.display * 0.6, weight: .regular,
        )
        glyph.contentTintColor = Slate.Native.Text.tertiary

        let title = NSTextField(labelWithString: reading.title)
        title.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        title.textColor = Slate.Native.Text.primary
        title.alignment = .center

        // Selectable rather than a label: see the type's note. `NSTextField(labelWithString:)` is not
        // selectable, so the flag is set after the fact — and `isBordered`/`drawsBackground` stay off,
        // which selectability alone would otherwise turn back on.
        let detail = NSTextField(labelWithString: reading.detail)
        detail.font = reading.detailIsCommand
            ? Slate.Typeface.instrumentNative(Slate.Typeface.footnote)
            : .systemFont(ofSize: Slate.Typeface.footnote)
        detail.textColor = Slate.Native.Text.secondary
        detail.alignment = .center
        detail.isSelectable = true
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0

        let stack = MacPanelCentredStack([glyph, title, detail])
        addSubview(stack)
        stack.pin(inside: self)
        // The detail is the only line that can wrap, so it is the only one given a width to wrap
        // WITHIN — without this the stack widens to the longest sentence and the panel scrolls.
        detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

/// The centred spinner surface — the code-server boot, the two service boots and the pre-push
/// `projectKey` wait share it, because all four are short-lived and all four resolve on their own.
@MainActor
final class MacPanelWaitingView: NSView {
    private let spinner = NSProgressIndicator()

    init(_ label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: Slate.Typeface.footnote)
        text.textColor = Slate.Native.Text.secondary
        text.alignment = .center

        let stack = MacPanelCentredStack([spinner, text])
        addSubview(stack)
        stack.pin(inside: self)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// AppKit spinners animate only while asked to. A spinner left running under an unmounted surface
    /// is a timer nobody looks at, so the animation rides the window membership rather than the init.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
}

/// The open gate — what a project shows before its first-ever workbench open (user-directed
/// 2026-08-07).
///
/// Same anatomy as the empty states so the panel keeps one voice, with two differences that are both
/// the gate's subject rather than its style: the detail is the FULL root in the instrument face,
/// middle-truncated to one line, and there is a button.
@MainActor
final class MacCodeOpenGateView: NSView {
    private let open: () -> Void

    init(projectRoot: String, open: @escaping () -> Void) {
        self.open = open
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(
            image: NSImage(
                systemSymbolName: CodeOpenGateReading.systemImage, accessibilityDescription: nil,
            ) ?? NSImage(),
        )
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.display * 0.6, weight: .regular,
        )
        glyph.contentTintColor = Slate.Native.Text.tertiary

        let title = NSTextField(labelWithString: CodeOpenGateReading.title(projectRoot: projectRoot))
        title.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        title.textColor = Slate.Native.Text.primary
        title.alignment = .center

        // MIDDLE truncation, one line: the head names the volume and the tail names the checkout, and
        // those are the two ends that tell two same-named projects apart. Truncating the tail would
        // drop exactly the half that answers the question the gate is asking.
        let path = NSTextField(labelWithString: projectRoot)
        path.font = Slate.Typeface.instrumentNative(Slate.Typeface.footnote)
        path.textColor = Slate.Native.Text.secondary
        path.alignment = .center
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1
        path.cell?.truncatesLastVisibleLine = true

        let button = MacPanelPlateButton(title: CodeOpenGateReading.openTitle) { open() }

        let stack = MacPanelCentredStack([glyph, title, path, button])
        // The button carries the panel's one text-button idiom and stands a rung apart from the lines
        // above it — a verb pressed against its own explanation reads as a fourth line of prose.
        stack.setCustomSpacing(Slate.Metric.space4, after: path)
        addSubview(stack)
        stack.pin(inside: self)
        path.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

// MARK: - The two pieces all three share

/// A vertical, centre-aligned stack on the panel's empty-state rhythm.
@MainActor
final class MacPanelCentredStack: NSStackView {
    init(_ views: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Slate.Metric.space2
        translatesAutoresizingMaskIntoConstraints = false
        for view in views { addArrangedSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Centre inside `host` with the panel's own margin, and never wider than it.
    ///
    /// Centred with `centerY`, NOT pinned top and bottom: a stack pinned to both edges of a surface
    /// that is 900pt tall one moment and 200pt the next stretches its spacing rather than staying a
    /// group, and the empty state is a group.
    func pin(inside host: NSView) {
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            centerYAnchor.constraint(equalTo: host.centerYAnchor),
            widthAnchor.constraint(
                lessThanOrEqualTo: host.widthAnchor, constant: -Slate.Metric.space4 * 2,
            ),
        ])
    }
}

/// The panel's one text-button idiom — the same plate the stage views' "Try Again" wears: hover lights
/// the fill a rung, the press drops it back.
///
/// A bespoke `NSView` rather than a bordered `NSButton` because the plate is the design's, not the
/// platform's: `NSButton`'s bezel draws its own material and its own corner, and a button that looked
/// like the panel would then be a button drawn twice.
@MainActor
final class MacPanelPlateButton: NSView {
    private let action: () -> Void
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { applyFill() } }
    private var pressed = false { didSet { applyFill() } }

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // `radiusControl`, the same rung `SlatePlateStyle` gives the phone's plate — the two halves
        // draw one button, and a corner is the part of it a reader can see disagree.
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous

        label.stringValue = title
        label.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        label.textColor = Slate.Native.Text.primary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
        applyFill()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }
    override func mouseDown(with _: NSEvent) { pressed = true }

    /// Fires on the UP, and only inside — a press dragged off the plate is a press taken back, which is
    /// the platform's own contract for every button on screen beside this one.
    override func mouseUp(with event: NSEvent) {
        pressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    private func applyFill() {
        let fill: SlateNativeColor = hovering && !pressed
            ? Slate.Native.State.selected
            : Slate.Native.Surface.raised
        layer?.backgroundColor = fill.cgColor
    }
}
