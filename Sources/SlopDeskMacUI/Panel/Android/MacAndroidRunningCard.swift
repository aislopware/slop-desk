// MacAndroidRunningCard — an attached device in the list, drawn at its own proportions, in AppKit
// (docs/56 stage D, increment 52b).
//
// The Mac's half of ``AndroidRunningCard``. Everything the card SAYS — the tooltip, the state
// sentence, the aspect clamp — is ``AndroidPresentation``'s and shared with the phone; what is here is
// the box, the fills and the pointer.
//
// A CARD AND NOT A ROW, for the reason its simulator twin gives: an attached device is the thing you
// are most likely to want, and the shape of its screen is worth the width.
//
// BUT NOT A LIVE THUMBNAIL, which is where the two panels part. The measurement is in
// ``MacAndroidDeviceList``'s header: `adb exec-out screencap -p` is 300 KB in ~250 ms with no scale or
// quality parameter to soften it, against 13.5 KB in 22 ms for the simulator server's scaled JPEG. A
// two-second poll per listed device would be 150 KB/s and a real slice of a phone's CPU, to fill a box
// a fifth of a panel wide. That is also why THIS class has no polling loop at all, and why its
// simulator twin does: the whole difference between the two cards is one measurement.
//
// WHAT THE BOX HOLDS INSTEAD is the device's true PROPORTIONS. Android reports its screen size
// exactly, booted or not, so the rectangle drawn here is the rectangle the device is — a phone comes
// out 92 wide at this height and a tablet 150, side by side and unmistakable, which is most of what
// the picture was carrying. It is the same claim the simulator card makes and the same one it declines
// to make: the SHAPE, which is known, and not the SIZE, which is not.
//
// A DEVICE THAT IS ATTACHED BUT NOT USABLE gets the same card with its state said out loud. That is
// the case worth designing for: `unauthorized` means a dialog is waiting on the device's own screen,
// and it is the one condition where the panel can do nothing at all and the user can fix it in two
// seconds — provided they are told.

import AppKit
import SFSafeSymbols
import SlopDeskClientCore // `ObservationFollow` — the one spelling of the re-arm
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacAndroidRunningCard: NSView {
    private let model: AndroidSidebarModel
    private let device: AndroidDevice
    private let onOpen: () -> Void
    private let onMenu: (AndroidDevice) -> NSMenu?

    private let spinner = MacDevicePanelSpinner()
    private var stop: MacDevicePanelGlyphButton?
    private var hovering = false { didSet { fade() } }

    init(
        model: AndroidSidebarModel, device: AndroidDevice,
        onMenu: @escaping (AndroidDevice) -> NSMenu?, onOpen: @escaping () -> Void,
    ) {
        self.model = model
        self.device = device
        self.onOpen = onOpen
        self.onMenu = onMenu
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth
        toolTip = AndroidPresentation.cardHelp(device)

        let art = art
        let caption = caption
        let stack = NSStackView(views: [art, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Both bands span the card: the art bed so its box can be CENTRED inside it, the caption
            // so its trailing control sits at the card's edge rather than at the name's.
            art.widthAnchor.constraint(equalTo: stack.widthAnchor),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])
        repaint()
        followPending()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The picture that is not one

    /// The screen box: a FIXED height and a width that follows the device's own aspect, so what varies
    /// between two cards is the shape and nothing else. The three LENGTHS are this half's, because
    /// they are design tokens and Slate sits above the target the arithmetic lives in.
    ///
    /// The family glyph sits inside it rather than a picture. Large — this is the one place in the
    /// panel where a silhouette has room to be read rather than to be a bullet — and in the icon ink,
    /// so the rectangle's proportions stay the loudest thing about the box.
    private var art: NSView {
        let box = MacAndroidArtBox()
        box.translatesAutoresizingMaskIntoConstraints = false

        let inner: NSView =
            if device.isAttachedButUnusable {
                // The one state that gets a word instead of a glyph. `unauthorized` is fixed by looking
                // at the device, and a symbol cannot say that.
                Self.stateLabel(AndroidPresentation.explain(device))
            } else {
                Self.familyGlyph(device)
            }
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)

        let width = AndroidPresentation.artWidth(
            for: device,
            art: Slate.Metric.deviceCardArt,
            floor: Slate.Metric.heightBar,
            cap: Slate.Metric.deviceCardWidth,
        )
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            box.heightAnchor.constraint(equalToConstant: Slate.Metric.deviceCardArt),
            inner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            inner.leadingAnchor.constraint(
                greaterThanOrEqualTo: box.leadingAnchor, constant: Slate.Metric.space1,
            ),
        ])

        // The box is CENTRED in the card, not leading — two cards of different shapes side by side
        // read as two devices only if each shape is centred under its own caption.
        let bed = NSView()
        bed.translatesAutoresizingMaskIntoConstraints = false
        bed.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: bed.centerXAnchor),
            box.topAnchor.constraint(equalTo: bed.topAnchor),
            box.bottomAnchor.constraint(equalTo: bed.bottomAnchor),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: bed.leadingAnchor),
        ])
        return bed
    }

    private static func familyGlyph(_ device: AndroidDevice) -> NSView {
        let glyph = NSImageView(
            image: NSImage(
                systemSymbolName: AndroidDeviceKind.infer(device).symbol.rawValue,
                accessibilityDescription: nil,
            ) ?? NSImage(),
        )
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.display, weight: .light,
        )
        glyph.contentTintColor = MacAndroidInk.color(.icon)
        return glyph
    }

    /// The unusable device's sentence. WRAPS, unlike every other label in this panel: it is a whole
    /// clause inside a box a phone's width wide, and truncating it would cut off exactly the half that
    /// says what to do about it.
    private static func stateLabel(_ words: String) -> NSTextField {
        let label = macDevicePanelLabel(
            words, size: Slate.Typeface.footnote, color: MacAndroidInk.color(.tertiary),
        )
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        label.preferredMaxLayoutWidth = Slate.Metric.deviceCardWidth - 2 * Slate.Metric.space2
        return label
    }

    // MARK: The caption

    private var caption: NSView {
        let name = macDevicePanelLabel(
            device.name, size: Slate.Typeface.base, weight: .medium,
            color: MacAndroidInk.color(.primary),
        )
        let identity = NSStackView(views: [name])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 0
        if !device.summary.isEmpty {
            identity.addArrangedSubview(macDevicePanelLabel(
                device.summary, size: Slate.Typeface.footnote,
                color: MacAndroidInk.color(.tertiary),
            ))
        }
        identity.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let line = NSStackView(views: [macAndroidFamilyMark(device), identity, spacer])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = Slate.Metric.space1
        line.translatesAutoresizingMaskIntoConstraints = false
        line.addArrangedSubview(spinner)
        if let stop = makeStop() {
            self.stop = stop
            line.addArrangedSubview(stop)
        }
        // The NAME yields its width first: the stop plate is fixed and a clipped verb would be a
        // control the pointer cannot reach, while a clipped name is still a name.
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return line
    }

    /// Stop, and only for an emulator. A physical device is somebody's phone: this panel mirrors it
    /// and does not power it off, so the plate is simply ABSENT rather than present-and-refusing.
    private func makeStop() -> MacDevicePanelGlyphButton? {
        guard device.isEmulator, device.isRunning else { return nil }
        return MacDevicePanelGlyphButton(
            symbol: .stopFill, help: AndroidPresentation.shutDownHelp(device),
            tint: MacAndroidInk.color(.tertiary),
        ) { [model, device] in
            Task { await model.shutdown(device) }
        }
    }

    // MARK: The lifecycle latch

    /// The card's one live reading: whether a lifecycle verb is in flight for this device.
    ///
    /// ⚠️ Only the properties READ inside `read` are observed, so adding a reading here means reading
    /// it there rather than in `apply`.
    private func followPending() {
        ObservationFollow.arm(self) { card in
            card.model.pending.contains(card.device.key)
        } apply: { card, pending in
            card.spinner.isHidden = !pending
            card.stop?.isHidden = pending
        }
    }

    // MARK: The pointer

    private func repaint() {
        layer?.backgroundColor = (hovering ? Slate.Native.State.selected : Slate.Native.Surface.raised)
            .cgColor
        layer?.borderColor = Slate.Native.Line.card.cgColor
        stop?.tint = MacAndroidInk.color(hovering ? .primary : .tertiary)
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            repaint()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }

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

    /// Fires on the UP and only inside. The GUARD is ``AndroidPresentation/canEnter(_:)``: a booting
    /// emulator opens (the stage knows how to wait for a device), an attached-but-unusable phone does
    /// not (its fix is a dialog on its own screen, which is not something waiting can do).
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        guard AndroidPresentation.canEnter(device) else { return }
        onOpen()
    }

    override func menu(for _: NSEvent) -> NSMenu? { onMenu(device) }
}

/// The card's art bed — its own class only so the fill can follow the appearance, which a bare `NSView`
/// with a `CGColor` cannot: a layer holds a FLAT colour, so a dynamic `NSColor` resolved once at build
/// time is the light theme's grey forever.
@MainActor
private final class MacAndroidArtBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
        }
    }
}
