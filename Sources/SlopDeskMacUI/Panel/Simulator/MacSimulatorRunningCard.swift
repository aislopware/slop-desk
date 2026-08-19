// MacSimulatorRunningCard — a running device in the list, drawn as its own screen, in AppKit
// (docs/56 stage D, increment 52a).
//
// WHY A CARD AND NOT A ROW. The panel is ~700pt wide and, for a device that is OFF, the server knows
// exactly four things about it: name, runtime, state, udid. Three are already on screen and the fourth
// is in the context menu, so there is no fifth fact to widen a row with — measured 2026-08-04,
// `definition.json` cannot supply one either, because it is CHROME data that falls back to a near model
// (iPhone Air comes back as the 17 Pro Max body; iPad Pro 11-inch, both iPad Airs and iPad (A16) all
// come back the same size). A size column built on it would be wrong for four of eleven devices, and a
// per-row silhouette would draw three of them as each other.
//
// A device that is RUNNING has a fact none of the others do: a screen. That is what fills the panel
// here, and it is why only the running group is drawn this way — the card is not a decorated row, it is
// the one place there is something to look at.
//
// THE PICTURE IS AFFORDABLE BECAUSE IT IS SMALL. `screenshot.jpg` at native resolution is 480 KB; the
// same capture at the server's `scale=6&quality=0.5` is 13.5 KB in 22 ms (both measured 2026-08-04 —
// see `SimulatorEndpoints.screenshot`). At ``SimulatorSidebarModel/thumbnailCadence`` that is 6.8 KB/s
// per running device, a fifth of what an idle VIDEO stream costs, where a native-resolution poll would
// have been seven times more than the stream.
//
// ⚠️ THE POLL DIES WITH THE VIEW, which on AppKit has to be said out loud. The phone hangs it on
// `.task(id:)` and gets the whole lifecycle free; here it rides window MEMBERSHIP, so a card scrolled
// out of a rebuilt list, a tab change or a panel collapse each stop it. Deliberately unlike the model's
// sockets, which outlive their view and needed an explicit `park()` — a card exists only while the list
// is on screen, so the view's own lifetime is exactly the right one.

import AppKit
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacSimulatorRunningCard: NSView {
    private let model: SimulatorSidebarModel
    private let device: SimulatorDevice
    private let onOpen: () -> Void

    private let art = NSImageView()
    /// The placeholder plate, shown for the second between a boot landing in the device list and the
    /// first capture coming back — and ONLY then.
    private let plate = NSView()
    private let stop: MacDevicePanelGlyphButton
    private let spinner = MacDevicePanelSpinner()

    private let poll = MacDevicePanelLoop()
    private var hovering = false { didSet { repaint() } }

    /// The last picture that arrived, kept across a FAILED poll rather than blanked: the server answers
    /// 500 for a device that has just gone away, and a card that flickered to grey for one round would
    /// be reporting a stumble the reader cannot act on.
    private var screen: NSImage?

    init(model: SimulatorSidebarModel, device: SimulatorDevice, onOpen: @escaping () -> Void) {
        self.model = model
        self.device = device
        self.onOpen = onOpen
        stop = MacDevicePanelGlyphButton(
            symbol: .stopFill, help: SimulatorPresentation.shutdownHelp(device),
            tint: Slate.Native.Text.tertiary,
        ) { Task { await model.shutdown(device.udid) } }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth
        toolTip = SimulatorPresentation.openHelp(device)

        buildArt()
        let caption = buildCaption()
        let stack = NSStackView(views: [artBox, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
            artBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        repaint()
        followPending()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    private let artBox = NSView()

    /// The screen box. A FIXED height and a free width, so what varies between two cards is the ASPECT
    /// and nothing else: a phone comes out 92 wide and an iPad 132, side by side and unmistakable.
    ///
    /// Not to true relative SIZE, and not by choice — an iPad mini really is the bigger object, but
    /// nothing here knows by how much. The capture's pixel dimensions are real and useless for this: the
    /// phone reports 1206 × 2622 at 3× and the iPad 1488 × 2266 at 2×, and the scale factor is in
    /// nothing the server sends. A normalised box is what is left, and it is the honest one — it claims
    /// the shape, which is known, and not the size, which is not.
    private func buildArt() {
        artBox.translatesAutoresizingMaskIntoConstraints = false

        // `raised` and not a flat tone: it is a TRANSLUCENT fill, so it tints the cream the card stands
        // on instead of substituting a grey from the system's aux palette for it. No spinner — the
        // capture is 22 ms, so an indicator would be a flash, and this panel has already been bitten
        // once by an indicator drawn from "nothing has arrived yet".
        plate.wantsLayer = true
        plate.layer?.cornerRadius = Slate.Metric.radiusCard
        plate.layer?.cornerCurve = .continuous
        plate.layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
        plate.translatesAutoresizingMaskIntoConstraints = false

        // The framebuffer is a rectangle; every device that can run this is not. Clipping to the card's
        // own radius is the smallest TRUE thing to say about the body — the server's real `clipRadius`
        // is part of the chrome data that falls back to the wrong model, so it is not worth being
        // precise with here.
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = Slate.Metric.radiusCard
        art.layer?.cornerCurve = .continuous
        art.layer?.masksToBounds = true
        art.isHidden = true
        art.translatesAutoresizingMaskIntoConstraints = false

        artBox.addSubview(plate)
        artBox.addSubview(art)
        NSLayoutConstraint.activate([
            artBox.heightAnchor.constraint(equalToConstant: Slate.Metric.deviceCardArt),
            plate.topAnchor.constraint(equalTo: artBox.topAnchor),
            plate.bottomAnchor.constraint(equalTo: artBox.bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: artBox.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: artBox.trailingAnchor),
            art.topAnchor.constraint(equalTo: artBox.topAnchor),
            art.bottomAnchor.constraint(equalTo: artBox.bottomAnchor),
            art.leadingAnchor.constraint(equalTo: artBox.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: artBox.trailingAnchor),
        ])
    }

    private func buildCaption() -> NSView {
        // The same family mark the rows carry. The picture above it already says iPad or iPhone louder
        // than a 13pt symbol can — but a card and a row for the same device should read the same way,
        // and for the second before the first capture the placeholder is the only thing above this line.
        let mark = macSimulatorFamilyMark(device)
        let name = macDevicePanelLabel(
            device.name, size: Slate.Typeface.base, weight: .medium,
            color: Slate.Native.Text.primary,
        )
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [mark, name, spacer, spinner, stop])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: Hover

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

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen()
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        macSimulatorDeviceMenu(model: model, device: device, onOpen: onOpen)
    }

    private func repaint() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = (hovering
                ? Slate.Native.State.selected
                : Slate.Native.Surface.raised).cgColor
            layer?.borderColor = Slate.Native.Line.card.cgColor
            // The card's own verb steps up an ink under the pointer, the same rule the list rows keep.
            stop.tint = hovering ? Slate.Native.Text.primary : Slate.Native.Text.tertiary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }

    // MARK: The verb's two shapes

    /// The stop button and the spinner occupy the SAME slot and swap rather than reflow. Both are
    /// `heightControl` square, so the caption does not move; what would move without this is the eye,
    /// because a glyph becoming a spinner in one frame reads as a redraw rather than as the click being
    /// accepted — and accepting the click is the whole of what the spinner is there to say.
    private func followPending() {
        var pending = false
        withObservationTracking {
            pending = self.model.pending.contains(self.device.udid)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followPending() }
            }
        }
        spinner.isHidden = !pending
        stop.isHidden = pending
    }

    // MARK: The picture

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            poll.cancel()
            return
        }
        poll.keyed(on: device.udid) { [weak self] in await self?.run() }
    }

    /// Ask for a picture, wait, ask again — for as long as this card is on screen.
    private func run() async {
        while !Task.isCancelled {
            if let data = await model.thumbnail(for: device.udid), let image = NSImage(data: data) {
                show(image)
            }
            try? await Task.sleep(for: SimulatorSidebarModel.thumbnailCadence)
        }
    }

    /// The FIRST picture fades in; the ones after it replace in place. Cross-fading every frame would
    /// smear a scroll or a keyboard appearing into a dissolve, which reads as a slow panel rather than
    /// as a live one.
    private func show(_ image: NSImage) {
        let isFirst = screen == nil
        screen = image
        art.image = image
        guard isFirst else { return }
        art.alphaValue = 0
        art.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.fadeSlideIn.duration
            context.timingFunction = Slate.Motion.fadeSlideIn.timingFunction
            art.animator().alphaValue = 1
            plate.animator().alphaValue = 0
        }
    }
}
