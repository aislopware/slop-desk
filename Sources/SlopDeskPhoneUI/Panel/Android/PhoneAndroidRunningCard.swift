// PhoneAndroidRunningCard — an attached device in the list, drawn at its own proportions.
//
// ``SlopDeskMacUI/MacAndroidRunningCard`` draws the same card in AppKit. What descended rather than
// being spelled twice: the aspect clamp (``AndroidPresentation/artWidth(for:art:floor:cap:)``), the
// tooltip, and the two `explain` folds — the last of which is the one this file most wanted to keep,
// and precisely the reason it could not: `adb`'s state words turned into English is a TABLE, and a
// table copied into a second framework grows a case on one side only.
//
// A CARD AND NOT A ROW, for the reason its simulator twin gives: an attached device is the thing you
// are most likely to want, and the shape of its screen is worth the width.
//
// BUT NOT A LIVE THUMBNAIL, which is where the two panels part. The measurement is in
// ``PhoneAndroidDeviceList``'s header: `adb exec-out screencap -p` is 300 KB in ~250 ms with no scale
// or quality parameter to soften it, against 13.5 KB in 22 ms for the simulator server's scaled JPEG.
// A two-second poll per listed device would be 150 KB/s and a real slice of a phone's CPU, to fill a
// box a fifth of a panel wide.
//
// WHAT THE BOX HOLDS INSTEAD is the device's true PROPORTIONS. Android reports its screen size
// exactly, booted or not, so the rectangle drawn here is the rectangle the device is — a phone comes
// out 92 wide at this height and a tablet 150, side by side and unmistakable, which is most of what
// the picture was carrying. It is the same claim the simulator card makes and the same one it
// declines to make: the SHAPE, which is known, and not the SIZE, which is not (nothing here knows a
// device's physical inches, and density is a rendering bucket rather than a ruler).
//
// A DEVICE THAT IS ATTACHED BUT NOT USABLE gets the same card with its state said out loud. That is
// the case worth designing for: `unauthorized` means a dialog is waiting on the device's own screen,
// and it is the one condition where the panel can do nothing at all and the user can fix it in two
// seconds — provided they are told.
//
// ⚠️ A `UIControl`, and REBUILT on every ``configure(device:)`` rather than mutated field by field.
// It lives inside a reusable cell, so it must be able to become a different device; a card is a
// handful of labels and one glyph, and diffing them against a new device would be more code than
// minting them. Nothing here is irreplaceable in docs/62 §3.4's sense — that rule is what stops the
// SIMULATOR's card, which owns a two-second thumbnail poll, from ever becoming one of these.

#if os(iOS)
import QuartzCore
import SFSafeSymbols
import SlopDeskClientCore // `ObservationFollow` — a REUSED card re-follows, so it needs the replacing arm
import SlopDeskDevicePanels
import SlopDeskSlate
import UIKit

@MainActor
final class PhoneAndroidRunningCard: UIControl {
    /// Enter this device's mirror. Held rather than passed per configure, because the list's own
    /// `enter` is one closure for every card in it.
    var onOpen: ((AndroidDevice) -> Void)?

    private let model: AndroidSidebarModel
    private let body = UIStackView()
    private var device: AndroidDevice?
    /// The pointer is over the card. iPadOS with a trackpad has hover exactly as the Mac does; a
    /// touch-only device never sets it and the card reads press-only.
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            paint()
        }
    }

    /// ⚠️ THIS FOLLOW IS RE-ARMED PER `configure`, because a card is REUSED — hence the handle, and
    /// hence `replacing:`. The arm made for the device this card drew last must not survive into the
    /// one it draws now.
    private var pendingFollow: ObservationFollow?

    init(model: AndroidSidebarModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusCard
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.cardBorderWidth

        body.translatesAutoresizingMaskIntoConstraints = false
        body.axis = .vertical
        body.alignment = .fill
        body.spacing = Slate.Metric.space2
        body.isUserInteractionEnabled = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            body.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: Self, _: UITraitCollection) in
            card.paint(animated: false)
        }
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            paint()
        }
    }

    // MARK: Content

    func configure(device: AndroidDevice) {
        self.device = device
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        body.addArrangedSubview(art(device))
        body.addArrangedSubview(caption(device))

        slateHelp(AndroidPresentation.cardHelp(device))
        // The whole card is one hit target and one VoiceOver element; the pieces inside it are drawing.
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(device.name). \(device.summary)"

        followPending()
    }

    /// The screen box: a FIXED height and a width that follows the device's own aspect, so what varies
    /// between two cards is the shape and nothing else.
    ///
    /// The family glyph sits inside it rather than a picture. Large — this is the one place in the
    /// panel where a silhouette has room to be read rather than to be a bullet — and in the icon ink,
    /// so the rectangle's proportions stay the loudest thing about the box.
    private func art(_ device: AndroidDevice) -> UIView {
        // A carrier that is full width with the BOX centred inside it. The box's own width is the
        // device's aspect, and a stack that stretched it would throw away the one claim it makes.
        let carrier = UIView()
        carrier.translatesAutoresizingMaskIntoConstraints = false

        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = Slate.Native.Surface.raised
        box.layer.cornerRadius = Slate.Metric.radiusCard
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        carrier.addSubview(box)

        let inner: UIView
        if device.isAttachedButUnusable {
            // The one state that gets a word instead of a glyph. `unauthorized` is fixed by looking at
            // the device, and a symbol cannot say that.
            let text = UILabel()
            text.text = AndroidPresentation.explain(device)
            text.font = .systemFont(ofSize: Slate.Typeface.footnote)
            text.textColor = PhoneAndroidInk.color(.tertiary)
            text.textAlignment = .center
            text.numberOfLines = 0
            inner = text
        } else {
            let glyph = UIImageView()
            glyph.contentMode = .center
            glyph.tintColor = PhoneAndroidInk.color(.icon)
            glyph.image = UIImage(
                systemName: AndroidDeviceKind.infer(device).symbol.rawValue,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Slate.Typeface.display, weight: .light,
                ),
            )?.withRenderingMode(.alwaysTemplate)
            inner = glyph
        }
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: boxWidth(device)),
            box.heightAnchor.constraint(equalToConstant: Slate.Metric.deviceCardArt),
            box.centerXAnchor.constraint(equalTo: carrier.centerXAnchor),
            box.topAnchor.constraint(equalTo: carrier.topAnchor),
            box.bottomAnchor.constraint(equalTo: carrier.bottomAnchor),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: carrier.leadingAnchor),
            inner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            inner.leadingAnchor.constraint(
                greaterThanOrEqualTo: box.leadingAnchor, constant: Slate.Metric.space1,
            ),
            inner.trailingAnchor.constraint(
                lessThanOrEqualTo: box.trailingAnchor, constant: -Slate.Metric.space1,
            ),
        ])
        return carrier
    }

    /// The box's width at the card's fixed art height, from the device's own aspect ratio, clamped so
    /// an unreported or absurd ratio cannot produce a box wider than the card.
    ///
    /// The three LENGTHS are this half's, because they are design tokens and Slate sits above the
    /// target the arithmetic lives in; the fallback and the order of the clamp are shared, because
    /// those are the parts that would drift.
    private func boxWidth(_ device: AndroidDevice) -> CGFloat {
        AndroidPresentation.artWidth(
            for: device,
            art: Slate.Metric.deviceCardArt,
            floor: Slate.Metric.heightBar,
            cap: Slate.Metric.deviceCardWidth,
        )
    }

    private func caption(_ device: AndroidDevice) -> UIView {
        let line = UIStackView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = Slate.Metric.space1

        let words = UIStackView()
        words.axis = .vertical
        words.alignment = .leading
        words.spacing = 0

        let name = UILabel()
        name.text = device.name
        name.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        name.textColor = PhoneAndroidInk.color(.primary)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        words.addArrangedSubview(name)

        if !device.summary.isEmpty {
            let summary = UILabel()
            summary.text = device.summary
            summary.font = .systemFont(ofSize: Slate.Typeface.footnote)
            summary.textColor = PhoneAndroidInk.color(.tertiary)
            summary.numberOfLines = 1
            summary.lineBreakMode = .byTruncatingTail
            words.addArrangedSubview(summary)
        }
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        line.addArrangedSubview(phoneAndroidFamilyMark(device))
        line.addArrangedSubview(words)
        line.addArrangedSubview(control)
        return line
    }

    // MARK: The control

    /// Stop, and only for an emulator. A physical device is somebody's phone: this panel mirrors it
    /// and does not power it off, so the plate is simply absent rather than present-and-refusing.
    ///
    /// One slot rather than three views swapped in and out, so the card's caption keeps its width while
    /// the spinner and the plate cross-fade inside it.
    private let control = UIView()

    private func setControl(_ view: UIView?) {
        for existing in control.subviews { existing.removeFromSuperview() }
        guard let view else {
            controlWidth.isActive = true
            return
        }
        controlWidth.isActive = false
        view.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            view.topAnchor.constraint(equalTo: control.topAnchor),
            view.bottomAnchor.constraint(equalTo: control.bottomAnchor),
        ])
    }

    /// Collapses the slot when the card carries no verb — a physical device, which cannot be stopped.
    private lazy var controlWidth: NSLayoutConstraint = control.widthAnchor.constraint(
        equalToConstant: .zero,
    )

    /// ⚠️ Hazard 2, and the reason `pending` is followed HERE rather than in the list: a boot in
    /// flight for one device must not rebuild the whole list, which on a phone is the surface the
    /// finger is on. THIS IS CALLED ONCE PER `configure(device:)` on a card the collection reuses, so
    /// it arms `replacing:` the arm the previous device left behind.
    private func followPending() {
        guard let device else {
            pendingFollow?.stop()
            pendingFollow = nil
            return
        }
        pendingFollow = ObservationFollow.arm(self, replacing: pendingFollow) { card in
            card.model.pending.contains(device.key)
        } apply: { card, isPending in
            if isPending {
                card.setControl(phoneAndroidPendingSpinner())
            } else if device.isEmulator, device.isRunning {
                let stop = SlatePlateVerbButton(
                    symbol: .stopFill, help: AndroidPresentation.shutDownHelp(device),
                    size: Slate.Typeface.footnote, plate: Slate.Metric.heightControl,
                    tint: PhoneAndroidInk.color(.tertiary),
                ) { [weak card] in
                    guard let card else { return }
                    Task { await card.model.shutdown(device) }
                }
                card.setControl(stop)
            } else {
                card.setControl(nil)
            }
        }
    }

    // MARK: Events

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began,
             .changed: hovering = true
        default: hovering = false
        }
    }

    /// WHETHER THE TAP OPENS ANYTHING is ``AndroidPresentation/canEnter(_:)`` — the same predicate the
    /// list's own `enter(_:)` asks, which is the point: it used to be spelled here AND there, one edit
    /// away from a card that opens a booting emulator and a row that refuses it.
    @objc
    private func fire() {
        guard let device, AndroidPresentation.canEnter(device) else { return }
        onOpen?(device)
    }

    /// `layer.backgroundColor`/`borderColor` rather than the view's own, for
    /// ``SlateListRowView/paint(animated:)``'s reason: a `CGColor` is the only property a
    /// `CATransaction` can carry this token's bezier onto, and the fill has to fade.
    private func paint(animated: Bool = true) {
        let fill: UIColor = hovering || isHighlighted
            ? Slate.Native.State.selected
            : Slate.Native.Surface.raised
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
        layer.borderColor = Slate.Native.Line.card.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }
}
#endif
