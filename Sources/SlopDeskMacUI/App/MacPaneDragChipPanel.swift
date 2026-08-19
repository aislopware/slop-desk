// MacPaneDragChipPanel — the cursor-following drop chip, in AppKit (docs/56 stage D, increment 56e).
//
// WHAT IT IS. Once a pane drag leaves the content column, the canvas's in-tree overlay stops being able
// to draw for it — a SwiftUI overlay clips at its hosting view's edge, and this drag legitimately
// crosses into the sidebar, into another window, and onto bare desktop. So the chip that says what
// releasing here would do rides a borderless, non-activating, mouse-transparent `NSPanel` that follows
// the pointer in SCREEN coordinates. That part is unchanged from the SwiftUI original and always was
// AppKit: a panel is not a view, and there is no SwiftUI spelling of "a window above every other window
// that never takes a click".
//
// WHAT CHANGED. The panel's `contentView` was an `NSHostingView<PaneDragChipView>` over ~40 lines of
// SwiftUI capsule. It is ``MacPaneDragChip`` now — the same capsule, drawn with a layer and two
// subviews. The SwiftUI original is DELETED rather than kept for the phone, and the phone loses
// nothing: the whole block was already inside `#if os(macOS)`, because a platform with one window and
// no cursor has nothing for a cursor-following cross-window chip to do. iOS leaves
// ``PaneDragCoordinator``'s sink nil, which is the seam's designed answer and not a gap.
//
// ⚠️ THE SINK IS THE ONLY THING THE COORDINATOR KNOWS. ``PaneDragChipSink`` is two methods, and both
// take values ``PaneDropRegister`` has ALREADY resolved — the label and the mark. This file must never
// re-derive either: the whole reason the register exists is that "what would this drop do" is answered
// once, for the in-canvas ghost chip and for this capsule alike, so the two can never disagree mid-drag.
// The one decision left here is presentational and stated below (hidden over the canvas).
//
// ⚠️ THE CONTENT COMPARISON IS LOAD-BEARING, not an optimisation. `showChip` is called on every pointer
// frame; the capsule's text and glyph change only on a DESTINATION transition. Rebuilding the subviews
// per frame would relayout and re-measure a panel 60+ times a second for a string that did not change.
// The SwiftUI original got this from `PaneDragChipView: Equatable` plus a `lastContent` compare; the
// same compare is kept explicitly here, against a tiny `Content` value, because AppKit has no view
// identity to lean on. `setFrameOrigin` still runs every frame — that is the one thing that DID change.
//
// REJECTED: an `NSTextField`-only chip with the glyph as an inline `NSTextAttachment`. It measures
// differently from a stack (the attachment's baseline is not the glyph's optical centre), and the
// capsule's height then drifts from the in-canvas ghost chip's, which is the one comparison a user can
// actually make — both chips can be on screen in the same drag.

import AppKit
import SFSafeSymbols // the glyph name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // PaneDragChipSink / PaneDropRegister — the resolved outcome, decided below
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

// MARK: - The panel

/// A tiny borderless, non-activating, mouse-transparent panel carrying the drag's chip once the cursor
/// leaves the content column.
///
/// Built once and reused for the life of the app rather than per drag: an `NSPanel` is expensive enough
/// that creating one on the first pointer frame of every drag would be visible, and `orderOut` costs
/// nothing.
@MainActor
final class MacPaneDragChipPanel: PaneDragChipSink {
    init() {}

    private var panel: NSPanel?
    private var chip: MacPaneDragChip?
    private var lastContent: MacPaneDragChip.Content?

    /// Show/move the chip for this frame.
    ///
    /// HIDDEN OVER THE CANVAS, and this is the file's only presentational decision. The canvas draws its
    /// own in-tree ghost chip at the drop zone, which is the better affordance there because it is
    /// anchored to the geometry it describes; a floating twin trailing the cursor two points away would
    /// say the same thing twice, slightly out of step.
    func showChip(
        at screenPoint: CGPoint, drag: PaneDragCoordinator.Drag, label: String,
        mark: PaneDropRegister.Mark,
    ) {
        if case .canvas = drag.destination {
            hideChip()
            return
        }
        let content = MacPaneDragChip.Content(
            symbol: mark.symbol, label: label, cancels: drag.destination == .none,
        )
        let panel = ensurePanel()
        if lastContent != content {
            lastContent = content
            chip?.content = content
            if let size = chip?.fittingSize { panel.setContentSize(size) }
        }
        // The chip trails above-right of the pointer. Screen coordinates are bottom-left origin, so
        // BOTH offsets are positive and both read as "up and to the right" — the quadrant that keeps the
        // capsule out from under the hand holding the mouse. `trail` is not a design rung: it is the
        // cursor hot-spot clearance, which belongs to the pointer and not to the type or spacing ladder.
        panel.setFrameOrigin(NSPoint(x: screenPoint.x + Self.trail, y: screenPoint.y + Self.trail))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideChip() {
        panel?.orderOut(nil)
        lastContent = nil
    }

    /// Pointer clearance — far enough that the arrow's tip never overlaps the capsule's shadow.
    private static let trail: CGFloat = 14

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false // the chip capsule casts its own, on the Slate ladder
        created.ignoresMouseEvents = true
        created.level = .popUpMenu // above the workspace + every satellite while the drag is live
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        let view = MacPaneDragChip()
        created.contentView = view
        chip = view
        panel = created
        return created
    }
}

// MARK: - The capsule

/// The floating chip's drawing — the same capsule voice as the canvas overlay's ghost chip, so one drop
/// vocabulary spans the in-tree affordance and the cross-window panel.
///
/// The root view is TRANSPARENT and the capsule is a child inset by ``shadowRoom`` on all four sides. A
/// borderless panel clips at its content bounds, so a shadow cast by the root itself would be sliced off
/// at the capsule's edge — the inset is what gives it somewhere to fall.
@MainActor
final class MacPaneDragChip: NSView {
    /// Everything the chip draws, as one comparable value — see the panel's note on why the compare
    /// exists at all.
    struct Content: Equatable {
        let symbol: SFSymbol
        let label: String
        let cancels: Bool
    }

    var content = Content(symbol: .xmark, label: "", cancels: true) {
        didSet {
            guard content != oldValue else { return }
            apply()
        }
    }

    private let capsule = CapsuleView()
    private let glyph = NSImageView()
    private let text = NSTextField(labelWithString: "")

    /// Room for the capsule's cast — the ghost rung's radius plus its drop, so the softest edge of the
    /// shadow still lands inside the panel.
    private static let shadowRoom = Slate.Elevation.ghost.radius / 2 + Slate.Elevation.ghost.y

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [capsule, glyph, text] { view.translatesAutoresizingMaskIntoConstraints = false }

        text.isSelectable = false
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        glyph.setAccessibilityElement(false)

        addSubview(capsule)
        capsule.addSubview(glyph)
        capsule.addSubview(text)

        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.shadowRoom),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.shadowRoom),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: Self.shadowRoom),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.shadowRoom),

            glyph.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: Slate.DropChip.padH),
            glyph.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Slate.DropChip.glyphGap),
            text.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -Slate.DropChip.padH),
            text.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            text.topAnchor.constraint(equalTo: capsule.topAnchor, constant: Slate.DropChip.padV),
            text.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -Slate.DropChip.padV),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The chip is decoration for a live drag and is never a stop on the keyboard's tour — it exists for
    /// exactly as long as a button is held down, and VoiceOver has the drag's own announcements.
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    private func apply() {
        let ink = content.cancels ? Slate.Native.Text.tertiary : Slate.Native.Text.primary
        glyph.image = NSImage(systemSymbolName: content.symbol.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
        text.stringValue = content.label
        text.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        text.textColor = ink
        capsule.cancels = content.cancels
        setAccessibilityLabel(content.label)
    }

    /// The capsule plate: a fill, a rim whose ROLE carries the verdict, and the ghost-rung cast.
    private final class CapsuleView: NSView {
        var cancels = false { didSet { needsDisplay = true } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerCurve = .continuous
            layer?.borderWidth = Slate.Metric.hairline
            layer?.masksToBounds = false
            layer?.shadowRadius = Slate.Elevation.ghost.radius
            layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.ghost.y)
            layer?.shadowOpacity = 1
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }

        override func layout() {
            super.layout()
            // A true capsule, not a rounded rectangle: the radius follows the height, so the chip stays
            // a capsule at whatever height the label's line ends up being.
            layer?.cornerRadius = bounds.height / 2
        }

        override func updateLayer() {
            // `effectiveAppearance` has to be the CURRENT one while a dynamic colour resolves, or every
            // rung answers for whatever appearance happened to be drawing last.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Slate.Native.Surface.face.cgColor
                // THE RIM IS THE VERDICT. A committing drop wears the accent — the app's one "this will
                // happen" colour; a release that commits nothing wears the quiet ink, dimmed, because a
                // cancel has to be legible without ever looking like an outcome.
                layer?.borderColor = cancels
                    ? Slate.Native.Text.tertiary.slateScalingAlpha(Slate.DropChip.cancelRim).cgColor
                    : Slate.Native.accent.cgColor
                layer?.shadowColor = Slate.Native.State.shadow.cgColor
            }
        }
    }
}
