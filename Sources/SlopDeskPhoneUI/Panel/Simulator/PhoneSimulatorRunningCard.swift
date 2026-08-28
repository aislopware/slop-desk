// PhoneSimulatorRunningCard — a running device in the list, drawn as its own screen.
//
// WHY A CARD AND NOT A ROW. For a device that is OFF, the server knows exactly four things about it:
// name, runtime, state, udid. Three are already on screen and the fourth is in the context menu, so
// there is no fifth fact to widen a row with — measured 2026-08-04, `definition.json` cannot supply one
// either, because it is CHROME data that falls back to a near model (iPhone Air comes back as the 17
// Pro Max body; iPad Pro 11-inch, both iPad Airs and iPad (A16) all come back the same size). A size
// column built on it would be wrong for four of eleven devices, and a per-row silhouette would draw
// three of them as each other.
//
// A device that is RUNNING has a fact none of the others do: a screen. That is what fills the panel
// here, and it is why only the running group is drawn this way — the card is not a decorated row, it
// is the one place there is something to look at.
//
// THE PICTURE IS AFFORDABLE BECAUSE IT IS SMALL. `screenshot.jpg` at native resolution is 480 KB;
// the same capture at the server's `scale=6&quality=0.5` is 13.5 KB in 22 ms (both measured
// 2026-08-04). At the two-second cadence that is 6.8 KB/s per running device, a fifth of what an idle
// VIDEO stream costs, where a native-resolution poll would have been seven times more than the stream.
//
// ⚠️ THE POLL RIDES REUSE, NOT JUST THE WINDOW, and that is the one thing this half has that neither
// twin did. The deleted SwiftUI card hung the poll on `.task(id:)` over a view SwiftUI minted per
// device; the Mac's rides window membership over a view AppKit never recycles. A `UICollectionViewCell`
// is neither: it is handed to a second device the moment the first scrolls away. So the loop is
// cancelled and the picture cleared in `prepareForReuse` as well as on leaving the window — without
// that, a recycled cell either replays the first-picture fade for a device already showing one, or
// flashes device A's screen under device B's name.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhoneSimulatorRunningCard: UICollectionViewCell {
    static let reuseIdentifier = "PhoneSimulatorRunningCard"

    /// The screen box. A FIXED height and a free width, so what varies between two cards is the ASPECT
    /// and nothing else: a phone comes out narrow and an iPad wide, side by side and unmistakable.
    ///
    /// Not to true relative SIZE, and not by choice — an iPad mini really is the bigger object, but
    /// nothing here knows by how much. The capture's pixel dimensions are real and useless for this:
    /// the phone reports 1206 × 2622 at 3× and the iPad 1488 × 2266 at 2×, and the scale factor is not
    /// in anything the server sends. A normalised box is what is left, and it is the honest one: it
    /// claims the shape, which is known, and not the size, which is not.
    private let art = UIImageView()
    /// What a card shows for the second between a boot landing in the device list and the first
    /// capture coming back — and ONLY then. A plate left permanently behind the picture letterboxes
    /// it: a phone is 92 of the box's 164 points, so the grey either side of the screen reads as a
    /// second rectangle rather than as the card's own padding. No spinner: the capture is 22 ms, so an
    /// indicator would be a flash, and this panel has been bitten once already by an indicator drawn
    /// from "nothing has arrived yet" (docs/47).
    private let plate = UIView()
    private let mark = UIView()
    private let name = UILabel()
    private let spinner = phoneSimulatorPendingSpinner()
    private let stop = SlatePlateVerbButton(
        symbol: .stopFill, size: Slate.Typeface.footnote, plate: Slate.Metric.heightControl,
    )
    private var caption = UIStackView()

    private let poll = PhoneSimulatorLoop()
    private var model: SimulatorSidebarModel?
    private var device: SimulatorDevice?
    /// A tap on the card enters the stage. Carried by the CELL rather than by the collection view's
    /// selection, because the row cells beside it are driven by ``SlateListRowView``'s own recogniser
    /// and a shell that swallows the touch — one tap path for both depths, or the two disagree about
    /// what a press on a device means.
    private var onOpen: (() -> Void)?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            paint()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = Slate.Metric.radiusCard
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = Slate.Metric.cardBorderWidth

        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.layer.cornerRadius = Slate.Metric.radiusCard
        plate.layer.cornerCurve = .continuous
        // `raised` and not a flat tone: it is a TRANSLUCENT fill, so it tints the cream the card stands
        // on instead of substituting a grey from the system's aux palette for it.
        plate.backgroundColor = Slate.Native.Surface.raised

        art.translatesAutoresizingMaskIntoConstraints = false
        art.contentMode = .scaleAspectFit
        // The framebuffer is a rectangle; every device that can run this is not. Clipping to the card's
        // own radius is the smallest true thing to say about the body — the server's real `clipRadius`
        // is part of the chrome data that falls back to the wrong model.
        art.layer.cornerRadius = Slate.Metric.radiusCard
        art.layer.cornerCurve = .continuous
        art.clipsToBounds = true
        art.alpha = 0

        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        name.textColor = Slate.Native.Text.primary
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stop.addAction(UIAction { [weak self] _ in
            guard let self, let model, let device else { return }
            Task { await model.shutdown(device.udid) }
        }, for: .touchUpInside)

        // The two occupy the SAME slot: both are `heightControl` square, so the caption does not move
        // when a shutdown goes in flight.
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            spinner.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])

        // The same family mark the rows carry. The picture above it already says iPad or iPhone louder
        // than a 13pt symbol can — but a card and a row for the same device should read the same way,
        // and for the second between a boot landing and the first capture the placeholder is the only
        // thing above this line. A CONTAINER, because the glyph itself is re-minted per device and a
        // stack's arranged subview cannot be swapped without re-running the whole caption's layout.
        mark.translatesAutoresizingMaskIntoConstraints = false

        caption = UIStackView(arrangedSubviews: [mark, name, spinner, stop])
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.axis = .horizontal
        caption.alignment = .center
        caption.spacing = Slate.Metric.space1

        for view in [plate, art] { contentView.addSubview(view) }
        contentView.addSubview(caption)

        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Slate.Metric.space2),
            plate.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space2,
            ),
            plate.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            plate.heightAnchor.constraint(equalToConstant: Slate.Metric.deviceCardArt),
            art.topAnchor.constraint(equalTo: plate.topAnchor),
            art.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            art.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
            caption.topAnchor.constraint(equalTo: plate.bottomAnchor, constant: Slate.Metric.space2),
            caption.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            caption.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Slate.Metric.space2,
            ),
            mark.widthAnchor.constraint(equalToConstant: Slate.Metric.deviceMarkWidth),
            mark.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        // A `CGColor` on a layer is resolved at assignment, so the ONE trait that can change what it
        // should be has to re-run the paint.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: Self, _: UITraitCollection) in
            cell.paint()
        }
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func configure(
        model: SimulatorSidebarModel, device: SimulatorDevice, onOpen: @escaping () -> Void,
    ) {
        self.model = model
        self.device = device
        self.onOpen = onOpen
        name.text = device.name
        slateHelp(SimulatorPresentation.openHelp(device))
        stop.help = SimulatorPresentation.shutdownHelp(device)

        for old in mark.subviews { old.removeFromSuperview() }
        let glyph = phoneSimulatorFamilyMark(device)
        mark.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: mark.leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
        ])
        showPending(model.pending.contains(device.udid))
        startPolling()
    }

    /// The pending fold, driven by the list's own observation rather than by one per cell: a cell that
    /// watched `model.pending` would put one observation per visible card on a set that changes twice
    /// per boot.
    func showPending(_ isPending: Bool) {
        spinner.isHidden = !isPending
        stop.isHidden = isPending
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // See the header: a cell is handed to a second device, so the loop and the picture both have to
        // go or the next device inherits them.
        poll.cancel()
        art.image = nil
        art.alpha = 0
        plate.alpha = 1
        hovering = false
        model = nil
        device = nil
        onOpen = nil
    }

    @objc
    private func tapped() { onOpen?() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            poll.cancel()
            return
        }
        startPolling()
    }

    /// Ask for a picture, wait, ask again — for as long as this cell is on screen with this device in
    /// it. Cancellation is the cell leaving the window or being handed to another device, which covers
    /// the tab changing, the panel closing, a scroll, and a tap opening the stage.
    private func startPolling() {
        guard window != nil, let model, let device else { return }
        poll.keyed(on: device.udid) { [weak self] in
            while !Task.isCancelled {
                if let data = await model.thumbnail(for: device.udid),
                   let image = UIImage(data: data)
                {
                    self?.show(image)
                }
                // The LAST picture is kept across a failed poll rather than blanked: the server answers
                // 500 for a device that has just gone away, and a card that flickered to grey for one
                // round would be reporting a stumble the reader cannot act on.
                try? await Task.sleep(for: SimulatorSidebarModel.thumbnailCadence)
            }
        }
    }

    /// The FIRST picture fades in; the ones after it replace in place. Cross-fading every frame would
    /// smear a scroll or a keyboard appearing into a dissolve, which reads as a slow panel rather than
    /// as a live one.
    private func show(_ image: UIImage) {
        let isFirst = art.image == nil
        art.image = image
        guard isFirst else { return }
        phoneSimulatorAnimate(Slate.Motion.fadeSlideIn) { [art, plate] in
            art.alpha = 1
            plate.alpha = 0
        }
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began, .changed: hovering = true
        default: hovering = false
        }
    }

    private func paint() {
        let fill = hovering ? Slate.Native.State.selected : Slate.Native.Surface.raised
        contentView.backgroundColor = fill
        contentView.layer.borderColor = Slate.Native.Line.card
            .resolvedColor(with: traitCollection).cgColor
        stop.tint = hovering ? Slate.Native.Text.primary : Slate.Native.Text.tertiary
    }
}
#endif
