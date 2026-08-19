// MacAndroidDeviceList — the host's Android devices, in AppKit (docs/56 stage D, increment 52b).
//
// The Mac's half of ``AndroidDeviceList``. The filter, the two empty sentences, the row's subtitle,
// the stop-all's arithmetic and the whole context-menu table are ``AndroidPresentation``'s and shared
// with the phone; what is here is the scroll view, the grids, the rows and the pointer.
//
// Structurally the twin of the Simulators list: a search plate, attached devices lifted into their own
// group above, the rest cut by family, both groups in a grid whose column count follows the panel
// width, and every row carrying its verb at rest in the tertiary ink.
//
// ⚠️ THE ONE PLACE THE TWO PANELS DIVERGE — and it is the interesting one.
//
// The simulator list draws a running device as a live thumbnail, because for a device that is OFF the
// server knows four things and three are already on screen: the bareness was a want of SUBJECT, and
// the picture was the only subject available. Android inverts BOTH halves of that:
//
//   - A shut-down AVD has an exact `config.ini` — screen size, density, device profile, ABI, API
//     level. There is a fact line to draw, so a row that is not running is not bare.
//   - A running device's picture is EXPENSIVE. Measured 2026-08-04 on this host's emulator:
//     `adb exec-out screencap -p` is 300 KB in ~250 ms, three runs, no variance worth reporting. There
//     is no scale or quality parameter — `screencap` renders at native size and PNG-encodes ON THE
//     DEVICE — so at the simulator card's two-second cadence that is 150 KB/s and a fat slice of a
//     phone's core per listed device. The simulator's equivalent is 13.5 KB in 22 ms.
//
// So the arithmetic that made a live card obviously right over there makes it obviously wrong here,
// and the fact that made it necessary is absent. A picture is taken when somebody asks for one (the
// context menu, or the stage's own capture button).
//
// ⚠️ THE LIST REBUILDS WHOLE, and that is a deliberate reading of what this data is. A poll round
// arrives as a NEW `[AndroidDevice]` every four seconds; there is no row identity to diff against
// because a device's whole state — its section, its verb, its subtitle — can change in one round, and
// the visible reflow (a booted device leaving its family for ATTACHED, everything under the cut
// shifting) is the news rather than the cost. The rebuild is gated on the devices actually differing,
// so a poll that returns the same list rebuilds nothing at all.

import AppKit
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacAndroidDeviceList: NSView {
    private let model: AndroidSidebarModel
    /// The way IN, handed down rather than taken here: entering a device is the panel's drill between
    /// its two depths, and the transaction that carries it belongs to the surface that owns both.
    private let onEnter: (AndroidDevice) -> Void

    private lazy var search = MacAndroidSearchPlate(
        placeholder: AndroidPresentation.searchPlaceholder,
    ) { [weak self] _ in self?.rebuild() }

    private let scroll = NSScrollView()
    private let document = MacAndroidListDocument()
    private let notice = macAndroidLabel(
        "", size: Slate.Typeface.footnote, color: MacAndroidInk.color(.tertiary),
    )

    /// What the last rebuild drew, so a poll round that changed nothing costs nothing.
    private var drawn: [String] = []

    init(model: AndroidSidebarModel, onEnter: @escaping (AndroidDevice) -> Void) {
        self.model = model
        self.onEnter = onEnter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        notice.maximumNumberOfLines = 0
        notice.lineBreakMode = .byWordWrapping
        notice.alignment = .center
        notice.translatesAutoresizingMaskIntoConstraints = false

        addSubview(search)
        addSubview(scroll)
        addSubview(notice)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            search.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space2,
            ),
            scroll.topAnchor.constraint(
                equalTo: search.bottomAnchor, constant: Slate.Metric.space2,
            ),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            scroll.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space2,
            ),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The document is as wide as the clip view, never wider: the grids inside it decide their
            // own column count from that width, so a document free to grow horizontally would answer
            // "one column, very wide" forever.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            notice.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Slate.Metric.space4,
            ),
        ])
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
    }

    // MARK: Following the model

    /// ⚠️ `withObservationTracking` fires ONCE per registration, so the callback re-arms by calling
    /// this again on the next main-queue turn. Only what is READ inside the tracked block is observed —
    /// the device list is the whole of it, because everything else this surface draws is derived from
    /// it and a row's own spinner does its own tracking (``MacAndroidDeviceRow``).
    private func follow() {
        withObservationTracking {
            _ = self.model.devices
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        rebuild()
    }

    private func rebuild() {
        let devices = model.devices
        let matches = AndroidPresentation.matches(devices, query: search.query)
        let sections = AndroidDeviceSections.sections(for: matches)
        let identities = sections.flatMap(\.rowIdentities)
        // The FILTER's own reading is part of the identity: two different queries can select the same
        // rows, but only one of them has an empty-state to draw.
        let signature = [search.query] + identities
        guard signature != drawn else { return }
        drawn = signature

        if devices.isEmpty {
            show(notice: AndroidPresentation.noDevices)
            return
        }
        if matches.isEmpty {
            show(notice: AndroidPresentation.noMatches(search.query))
            return
        }
        notice.isHidden = true
        scroll.isHidden = false
        document.fill(sections.flatMap(views(for:)))
    }

    /// A FAILED POLL DRAWS NOTHING HERE, for the reason the simulator list records: the last-known
    /// devices are still the best information available, the report goes to the window's notification
    /// card like every other report this panel makes, and two bespoke alert shapes in one panel was
    /// the thing being fixed. This is only the two EMPTY readings, which are two different failures
    /// and must not be one.
    private func show(notice text: String) {
        notice.stringValue = text
        notice.isHidden = false
        scroll.isHidden = true
        document.fill([])
    }

    // MARK: One section

    private func views(for section: AndroidListSection) -> [NSView] {
        [heading(section), section.isRunning ? shelf(section) : grid(section)]
    }

    private func heading(_ section: AndroidListSection) -> NSView {
        // WHICH devices a stop-all may act on is ``AndroidPresentation/stoppable(in:)``, and it is
        // offered only where more than one is up — below that it is the same verb as the card's own
        // stop button, one row away.
        let stoppable = AndroidPresentation.stoppable(in: section.devices)
        var accessory: NSView?
        if section.isRunning, stoppable.count > 1 {
            accessory = MacAndroidGlyphButton(
                symbol: .stopCircle,
                help: AndroidPresentation.shutDownAllHelp(count: stoppable.count),
                tint: MacAndroidInk.color(.tertiary),
            ) { [model] in
                Task { await model.shutdownAll() }
            }
        }
        return MacAndroidSectionHeader(
            section.title, caption: section.version, accessory: accessory,
        )
    }

    /// The attached group: fixed-width cards, because a card's width IS the device's shape and a card
    /// stretched to share the panel would make the one claim it exists to make a lie.
    private func shelf(_ section: AndroidListSection) -> NSView {
        MacAndroidGrid(
            cells: section.devices.map { device in
                MacAndroidRunningCard(
                    model: model, device: device, onMenu: { [weak self] in self?.menu(for: $0) },
                ) { [onEnter] in onEnter(device) }
            },
            columnWidth: Slate.Metric.deviceCardWidth,
            isFixed: true,
            spacing: Slate.Metric.space2,
        )
    }

    /// Every other group: width-SHARING rows, because a row's content is a name and a name is happy to
    /// have more room.
    private func grid(_ section: AndroidListSection) -> NSView {
        MacAndroidGrid(
            cells: section.devices.map { device in
                MacAndroidDeviceRow(
                    model: model, device: device,
                    showsVersion: section.showsVersion(device),
                    onMenu: { [weak self] in self?.menu(for: $0) },
                )
            },
            columnWidth: Slate.Metric.deviceRowWidth,
            isFixed: false,
            spacing: Slate.Metric.space1,
        )
    }

    // MARK: The context menu

    /// The verb table is ``AndroidPresentation/menu(for:)``'s; this builds the `NSMenu` for it and
    /// carries each verb on the item's `representedObject`, so one action method serves every entry
    /// rather than a selector per verb.
    private func menu(for device: AndroidDevice) -> NSMenu {
        let menu = NSMenu()
        for entry in AndroidPresentation.menu(for: device) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .verb(verb):
                let item = NSMenuItem(title: verb.title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MacAndroidVerbBox(verb: verb, device: device)
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc
    private func run(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MacAndroidVerbBox else { return }
        AndroidPresentation.run(box.verb, device: box.device, on: model, enter: onEnter)
    }
}

/// A menu item's `representedObject` must be an `AnyObject`, and the verb is an enum with an
/// associated value — so it travels in a box rather than being flattened into a tag, which is the
/// alternative that loses the copied string.
@MainActor
private final class MacAndroidVerbBox {
    let verb: AndroidDeviceVerb
    let device: AndroidDevice

    init(verb: AndroidDeviceVerb, device: AndroidDevice) {
        self.verb = verb
        self.device = device
    }
}

/// The scroll view's document: a top-down vertical stack whose height is its content's.
@MainActor
private final class MacAndroidListDocument: NSStackView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        edgeInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: Slate.Metric.space2, right: 0,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Top-down, so the first section is at the TOP of the document rather than the bottom.
    override var isFlipped: Bool { true }

    func fill(_ views: [NSView]) {
        for view in arrangedSubviews { removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            addArrangedSubview(view)
            // A grid decides its column count from its own width, so it must be the document's full
            // width rather than its content's.
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
}

// MARK: - The row

/// One device that is not attached: its family mark, its name, the fact that tells it from its
/// look-alikes, and the one verb that applies.
@MainActor
final class MacAndroidDeviceRow: MacAndroidRowShell {
    private let model: AndroidSidebarModel
    private let device: AndroidDevice
    private let onMenu: (AndroidDevice) -> NSMenu?

    private let spinner = MacAndroidSpinner()
    private var start: MacAndroidGlyphButton?

    init(
        model: AndroidSidebarModel, device: AndroidDevice, showsVersion: Bool,
        onMenu: @escaping (AndroidDevice) -> NSMenu?,
    ) {
        self.model = model
        self.device = device
        self.onMenu = onMenu
        super.init(frame: .zero)

        content.addArrangedSubview(macAndroidFamilyMark(device))
        let name = macAndroidLabel(
            device.name, size: Slate.Typeface.base, color: MacAndroidInk.color(.primary),
        )
        content.addArrangedSubview(name)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        content.addArrangedSubview(spacer)

        // The trailing text: the platform version where the heading has not already said it, and the
        // SCREEN otherwise — the fact the simulator list could not print, and what tells two
        // similarly-named AVDs apart when they share a system image.
        if let subtitle = AndroidPresentation.subtitle(for: device, showsVersion: showsVersion) {
            let caption = macAndroidLabel(
                subtitle, size: Slate.Typeface.footnote, color: MacAndroidInk.color(.tertiary),
            )
            // The SUBTITLE yields before the name does: it qualifies, and a name that truncated so a
            // resolution could stay whole would be the wrong way round.
            caption.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            content.addArrangedSubview(caption)
        }
        content.addArrangedSubview(spinner)
        let start = MacAndroidGlyphButton(
            symbol: .playFill, help: AndroidPresentation.startHelp(device),
            tint: MacAndroidInk.color(.tertiary),
        ) { [model, device] in
            Task { await model.boot(device) }
        }
        self.start = start
        content.addArrangedSubview(start)

        // A click on a device that is not running STARTS it — the same intent a click on a card
        // carries, one step earlier, and refused while a lifecycle verb is already in flight
        // (``AndroidPresentation/open(_:on:)``).
        onTap = { [model, device] in AndroidPresentation.open(device, on: model) }
        followPending()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The one verb that applies, at REST but quiet: the glyph steps from the tertiary ink to the
    /// primary one while the pointer is anywhere on the row.
    override func hoverChanged(_ hovering: Bool) {
        start?.tint = MacAndroidInk.color(hovering ? .primary : .tertiary)
    }

    override func menu(for _: NSEvent) -> NSMenu? { onMenu(device) }

    /// The row's own live reading, tracked here rather than by the list: a boot in flight is one
    /// device changing, and re-arming the whole list for it would rebuild every other row.
    private func followPending() {
        var pending = false
        withObservationTracking {
            pending = self.model.pending.contains(self.device.key)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followPending() }
            }
        }
        spinner.isHidden = !pending
        start?.isHidden = pending
    }
}
