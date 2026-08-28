// PhoneAndroidDeviceList — the host's Android devices, drawn in Slate.
//
// ``SlopDeskMacUI/MacAndroidDeviceList`` draws the same depth in AppKit. What both halves read out of
// ``AndroidPresentation`` rather than spelling twice: the filter, the two empty sentences, the row's
// subtitle, the predicate that decides whether a tap opens a mirror at all, and the context menu's
// whole table. The GROUPING is ``AndroidDeviceSections``, which is `rust/slopdesk-devicepanel`'s and is
// shared with the simulator panel — one crossing decides the ordering for four renderers.
//
// A `UICollectionView`, which is docs/62 §3.4's ruling for this surface by name: the row count is a
// function of the user's SDK rather than of the design, the list is live-filtered on every keystroke,
// and `sections.flatMap(\.rowIdentities)` — what the deleted SwiftUI half handed `.animation(value:)`
// — is already a snapshot identifier list. THE ANIMATED APPLY IS THE REFLOW: a boot is not a row
// changing colour, it is a device leaving its family while ATTACHED appears above it and everything
// under the cut shifts, and a diffable apply is that move with nothing extra asked for.
//
// ⚠️ AN ITEM IDENTIFIER IS THE ROW IDENTITY, NEVER THE RENDERED CONTENT, and the identity is
// SECTION-QUALIFIED because the move a boot makes IS between sections — a plain list of device keys
// would not see it, and the card would be carried across instead of being minted in its new home.
// Hazard 3 follows from the same fact: nothing here indexes `devices[indexPath.item]`, because the
// array a snapshot was built from is not the array that is live when a cell is dequeued.
//
// ⚠️ THE ONE PLACE THE TWO DEVICE PANELS DIVERGE — and it is the interesting one.
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
// and the fact that made it necessary is absent. A running Android device is drawn as a card carrying
// its TRUE PROPORTIONS and its facts, and a picture is taken when somebody asks for one.

#if os(iOS)
import Observation
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
import UIKit

@MainActor
final class PhoneAndroidDeviceList: UIView {
    private let model: AndroidSidebarModel
    private let enter: (AndroidDevice) -> Void

    /// Filters as typed. Deliberately NOT persisted: a filter that survived a panel collapse would
    /// hide devices with nothing on screen to explain why.
    private var query = ""

    private let field = UIView()
    private let line: SlateSearchLine
    private let clear: UIControl
    /// Minted with a PLACEHOLDER layout, because the real one (``layout()``) reads `self` for the
    /// section it is asked about and phase 1 cannot. ``buildGrid()`` swaps it in before the first pass.
    private let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
    private var source: UICollectionViewDiffableDataSource<String, String>?
    private let notice = UIView()

    /// The two registrations, named because the generic pair is the whole of each one's opening line —
    /// spelled inline it leaves no room for the closure's parameters beside the brace.
    private typealias CardRegistration = UICollectionView.CellRegistration<PhoneAndroidCardCell, String>
    private typealias RowRegistration = UICollectionView.CellRegistration<PhoneAndroidRowCell, String>

    /// The sections as last drawn. Read by the layout's section provider and by the header provider,
    /// which are handed an INDEX and nothing else.
    private var sections: [AndroidListSection] = []
    /// Row identity → the device it draws. Rebuilt with every snapshot; a cell provider that misses
    /// here draws an empty cell rather than reaching for an index, which is what makes a snapshot that
    /// is one poll stale harmless.
    private var rows: [String: AndroidDevice] = [:]
    /// What was last drawn — the query and every row identity, in order. The gate that keeps a poll
    /// returning the same devices from re-applying a snapshot.
    private var drawn: [String] = []

    /// ⚠️ Hazard 2's counter, on the one re-arming observation this view owns.
    private var generation = 0

    init(model: AndroidSidebarModel, enter: @escaping (AndroidDevice) -> Void) {
        self.model = model
        self.enter = enter
        line = SlateSearchLine(placeholder: AndroidPresentation.searchPlaceholder)
        // The key is minted WITH its action and the action is `self`'s, which phase 1 cannot read — so
        // it is built against a box phase 2 fills. ``PhoneSimulatorConsoleView``'s trampoline exactly.
        var clearAction: (() -> Void)?
        clear = PhoneDevicePanelChrome.clearKey(ink: PhoneAndroidInk.color(.icon)) { clearAction?() }
        super.init(frame: .zero)
        clearAction = { [weak self] in
            guard let self else { return }
            line.text = ""
            // A programmatic write does not echo back through `.editingChanged`, so the field's own
            // change path has to be run by hand — which is the whole reason the key is not simply a
            // `clearButtonMode`.
            query = ""
            revealClear()
            rebuild()
        }
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.field

        buildField()
        buildGrid()

        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.alpha = 0
        addSubview(notice)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            field.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),

            grid.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Slate.Metric.space2),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),

            notice.topAnchor.constraint(equalTo: grid.topAnchor),
            notice.leadingAnchor.constraint(equalTo: leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: trailingAnchor),
            notice.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Filter

    private func buildField() {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.slateChromeFieldPlate()
        addSubview(field)

        let magnifier = UIImageView()
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.contentMode = .center
        magnifier.tintColor = PhoneAndroidInk.color(.icon)
        magnifier.image = UIImage(
            systemName: SFSymbol.magnifyingglass.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )?.withRenderingMode(.alwaysTemplate)

        line.onTextChange = { [weak self] text in
            guard let self else { return }
            query = text
            revealClear()
            rebuild()
        }

        clear.alpha = 0

        for view in [magnifier, line, clear] { field.addSubview(view) }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(
                equalTo: field.leadingAnchor, constant: Slate.Metric.space2,
            ),
            magnifier.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            line.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space1,
            ),
            line.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            line.trailingAnchor.constraint(equalTo: clear.leadingAnchor),
            clear.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            clear.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
    }

    /// The key appears on the FIRST keystroke and vanishes on the last — at a field's trailing edge
    /// that is a glyph blinking beside the caret, and the fade is what keeps it from reading as part
    /// of the typing.
    private func revealClear() {
        let wanted: CGFloat = query.isEmpty ? 0 : 1
        guard clear.alpha != wanted else { return }
        UIView.animate(withDuration: Slate.Motion.smallFade.duration) { [weak self] in
            self?.clear.alpha = wanted
        }
    }

    // MARK: The grid

    private func buildGrid() {
        grid.setCollectionViewLayout(layout(), animated: false)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.backgroundColor = .clear
        grid.alwaysBounceVertical = true
        grid.delegate = self
        grid.contentInset = UIEdgeInsets(
            top: 0, left: 0, bottom: Slate.Metric.space2, right: 0,
        )
        addSubview(grid)

        // ⚠️ TWO CELL CLASSES, NOT ONE CLASS WITH TWO CONTENTS, and the reflow is exactly why. A
        // dequeue pool is keyed by the cell's CLASS: with one `UICollectionViewCell` behind both
        // registrations, a device that boots — leaving the family grid for the shelf, which is the one
        // move this list is built around — hands the card registration a cell whose `contentView`
        // still holds a mounted row, constraints and pending arm and all. Two classes make that
        // impossible rather than guarded against.
        let card = CardRegistration { [weak self] cell, _, identity in
            guard let self, let device = rows[identity] else { return }
            cell.card(model: model) { [weak self] opened in self?.enter(opened) }
                .configure(device: device)
        }
        let row = RowRegistration { [weak self] cell, _, identity in
            guard let self, let device = rows[identity] else { return }
            cell.row(model: model)
                .configure(device: device, showsVersion: showsVersion(device, identity: identity))
        }

        source = UICollectionViewDiffableDataSource<String, String>(
            collectionView: grid,
        ) { [weak self] view, indexPath, identity in
            let isShelf = self?.section(at: indexPath.section)?.isRunning ?? false
            return isShelf
                ? view.dequeueConfiguredReusableCell(using: card, for: indexPath, item: identity)
                : view.dequeueConfiguredReusableCell(using: row, for: indexPath, item: identity)
        }

        let heading = UICollectionView.SupplementaryRegistration<PhoneAndroidHeadingView>(
            elementKind: UICollectionView.elementKindSectionHeader,
        ) { [weak self] view, _, indexPath in
            guard let self, let section = section(at: indexPath.section) else { return }
            view.configure(section: section) { [weak self] in
                guard let self else { return }
                Task { await self.model.shutdownAll() }
            }
        }
        source?.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: heading, for: indexPath)
        }
    }

    /// The two section shapes, chosen per section and sized against the width the panel actually has.
    ///
    /// ⚠️ THE COLUMN COUNT IS COMPUTED, because `UICollectionViewCompositionalLayout` has no adaptive
    /// group: the deleted `LazyVGrid(.adaptive(minimum:))` wrapped by itself, and the direct
    /// translation of "as many columns of at least this width as fit" is that division, run inside the
    /// section provider where the container's width is finally known.
    private func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let isShelf = self?.section(at: index)?.isRunning ?? false
            let inset = Slate.Metric.space2
            let usable = environment.container.effectiveContentSize.width - inset * 2
            let spacing = isShelf ? Slate.Metric.space2 : Slate.Metric.space1
            let minimum = isShelf ? Slate.Metric.deviceCardWidth : Slate.Metric.deviceRowWidth
            let columns = max(1, Int((usable + spacing) / (minimum + spacing)))

            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                heightDimension: .fractionalHeight(1),
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    // A shelf row is as tall as a card, which is the art box plus its caption; a grid
                    // row is the ONE row rung, always. Estimated only where the caption's second line
                    // is optional.
                    heightDimension: isShelf
                        ? .estimated(Slate.Metric.deviceCardArt + Slate.Metric.heightRowStacked)
                        : .absolute(Slate.Metric.heightRow),
                ),
                repeatingSubitem: item, count: columns,
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: inset, bottom: Slate.Metric.space2, trailing: inset,
            )
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(Slate.Metric.heightRow),
                ),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top,
            )]
            return section
        }
    }

    private func section(at index: Int) -> AndroidListSection? {
        index < sections.count ? sections[index] : nil
    }

    /// A device prints its own version only where the heading has not already said it — the crate's
    /// answer, asked of the section the row is actually in rather than of the first one that holds a
    /// device with this key.
    private func showsVersion(_ device: AndroidDevice, identity: String) -> Bool {
        guard let section = sections.first(where: { $0.rowIdentities.contains(identity) })
        else { return false }
        return section.showsVersion(device)
    }

    // MARK: Following the model

    /// ⚠️ `withObservationTracking` fires ONCE per registration, so the callback re-arms by calling
    /// this again on the next main-queue turn. Only the DEVICE LIST is read here: a boot in flight is
    /// followed by the row that draws its spinner (``PhoneAndroidRunningCard/followPending()``), which
    /// is what keeps one device's lifecycle verb from re-applying a snapshot under the finger.
    private func follow() {
        generation &+= 1
        let generation = generation

        var devices: [AndroidDevice] = []
        withObservationTracking {
            devices = self.model.devices
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        apply(devices)
    }

    private func rebuild() {
        apply(model.devices)
    }

    private func apply(_ devices: [AndroidDevice]) {
        let shown = AndroidPresentation.matches(devices, query: query)
        let built = shown.isEmpty ? [] : AndroidDeviceSections.sections(for: shown)

        // Two empty readings, and they are different sentences: a host with no devices at all, and a
        // filter that matched none of the ones there are.
        //
        // A FAILED POLL DRAWS NOTHING HERE. The last-known devices are still the best information
        // available, the report goes to the window's notification card like every other report this
        // panel makes, and two bespoke alert shapes in one panel was the thing being fixed.
        let message: String? =
            if devices.isEmpty {
                AndroidPresentation.noDevices
            } else if shown.isEmpty {
                AndroidPresentation.noMatches(query)
            } else {
                nil
            }
        setNotice(message)

        let signature = [query] + built.flatMap(\.rowIdentities)
        guard signature != drawn else { return }
        let isFirst = drawn.isEmpty
        drawn = signature
        sections = built
        rows = Dictionary(
            uniqueKeysWithValues: built.flatMap { section in
                zip(section.rowIdentities, section.devices)
            },
        )

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in built {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rowIdentities, toSection: section.id)
        }
        // THE REFLOW, and the first pass is not one: a list arriving into an empty panel has nothing
        // to move from, and animating it would read as the whole SDK sliding in.
        source?.apply(snapshot, animatingDifferences: !isFirst)
    }

    private func setNotice(_ text: String?) {
        for view in notice.subviews { view.removeFromSuperview() }
        if let text {
            let body = PhoneDevicePanelChrome.notice(text)
            notice.addSubview(body)
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: notice.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: notice.trailingAnchor),
                body.topAnchor.constraint(equalTo: notice.topAnchor),
                body.bottomAnchor.constraint(equalTo: notice.bottomAnchor),
            ])
        }
        // `alpha`, never `isHidden`: `layoutSubviews` does not run on a hidden subtree, so a notice
        // that arrived while hidden would come back unlaid-out (docs/62 §3.2).
        grid.isUserInteractionEnabled = text == nil
        UIView.animate(withDuration: Slate.Motion.smallFade.duration) { [weak self] in
            self?.notice.alpha = text == nil ? 0 : 1
            self?.grid.alpha = text == nil ? 1 : 0
        }
    }
}

// MARK: - The row menu

extension PhoneAndroidDeviceList: UICollectionViewDelegate {
    /// The menu is a TABLE from below (``phoneAndroidDeviceMenu(for:run:)``); what is decided here is
    /// only WHICH row was long-pressed, and that resolves through the snapshot rather than through an
    /// index — hazard 3, on the surface it was written for.
    func collectionView(
        _: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let identity = source?.itemIdentifier(for: indexPath),
              let device = rows[identity]
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: phoneAndroidDeviceMenu(for: device) { [weak self] verb in
                guard let self else { return }
                AndroidPresentation.run(verb, device: device, on: model, enter: enter)
            })
        }
    }
}

// MARK: - The heading

/// A section heading, with the stop-all it only sometimes carries.
///
/// WHICH devices a stop-all may act on is ``AndroidPresentation/stoppable(in:)`` — a physical device is
/// not something this panel may power off, so a control that named every attached device would promise
/// a verb it refuses for half of them.
@MainActor
private final class PhoneAndroidHeadingView: UICollectionReusableView {
    private let header = SlateSectionHeaderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func configure(section: AndroidListSection, stopAll: @escaping () -> Void) {
        header.title = section.title
        header.caption = section.version
        let stoppable = AndroidPresentation.stoppable(in: section.devices)
        guard section.isRunning, stoppable.count > 1 else {
            header.accessory = nil
            return
        }
        header.accessory = SlatePlateVerbButton(
            symbol: .stopCircle,
            help: AndroidPresentation.shutDownAllHelp(count: stoppable.count),
            size: Slate.Typeface.footnote, plate: Slate.Metric.heightControl,
            tint: PhoneAndroidInk.color(.tertiary), action: stopAll,
        )
    }
}

// MARK: - The two cells

/// A cell holding exactly one ``PhoneAndroidRunningCard``, minted on first use and reconfigured after.
///
/// ⚠️ ITS ONLY JOB IS TO BE A DISTINCT CLASS. A collection view pools reusable cells BY CLASS, so the
/// shelf and the family grid sharing `UICollectionViewCell` would let a booting device — the reflow
/// this whole list is shaped around — hand the card registration a cell whose `contentView` still
/// holds a mounted row, its constraints and its pending arm alive underneath.
@MainActor
private final class PhoneAndroidCardCell: UICollectionViewCell {
    private var mounted: PhoneAndroidRunningCard?

    func card(model: AndroidSidebarModel, onOpen: @escaping (AndroidDevice) -> Void)
        -> PhoneAndroidRunningCard
    {
        let card = mounted ?? mint(model: model)
        card.onOpen = onOpen
        return card
    }

    private func mint(model: AndroidSidebarModel) -> PhoneAndroidRunningCard {
        let card = PhoneAndroidRunningCard(model: model)
        contentView.addSubview(card)
        card.pin(to: contentView)
        mounted = card
        return card
    }
}

/// A cell holding exactly one ``PhoneAndroidDeviceRow``. The twin of ``PhoneAndroidCardCell``, and
/// separate for the same reason.
@MainActor
private final class PhoneAndroidRowCell: UICollectionViewCell {
    private var mounted: PhoneAndroidDeviceRow?

    func row(model: AndroidSidebarModel) -> PhoneAndroidDeviceRow {
        if let mounted { return mounted }
        let row = PhoneAndroidDeviceRow(model: model)
        contentView.addSubview(row)
        row.pin(to: contentView)
        mounted = row
        return row
    }
}

private extension UIView {
    func pin(to host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

// MARK: - The row

/// One device that is not running, on the app's ONE row anatomy (``SlateListRowView``).
///
/// ⚠️ IT NEVER SETS `active`. The Android list has ONE depth of selection — a selected device is not a
/// highlighted row, it is the STAGE — so a raised card here would claim a state this depth cannot be
/// in.
@MainActor
private final class PhoneAndroidDeviceRow: UIView {
    private let model: AndroidSidebarModel
    private let shell = SlateListRowView()
    private let name = UILabel()
    private let subtitle = UILabel()
    private let verb = UIView()
    private var device: AndroidDevice?
    /// ⚠️ Hazard 2's counter — a row is reused, so a boot's arm must not outlive the device it armed
    /// for.
    private var generation = 0

    init(model: AndroidSidebarModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        name.font = .systemFont(ofSize: Slate.Typeface.base)
        name.textColor = PhoneAndroidInk.color(.primary)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail

        subtitle.font = .systemFont(ofSize: Slate.Typeface.footnote)
        subtitle.textColor = PhoneAndroidInk.color(.tertiary)
        subtitle.numberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        // The subtitle is what yields inside the trailing cluster: the verb is a fixed plate and must
        // stay a whole tap target.
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The slot is the plate's own size: every row in this depth has exactly one verb — start it —
        // and the spinner that stands in while it runs is the same square.
        verb.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            verb.widthAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            verb.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])

        let cluster = UIStackView(arrangedSubviews: [subtitle, verb])
        cluster.axis = .horizontal
        cluster.alignment = .center
        cluster.spacing = Slate.Metric.space1

        shell.title = name
        shell.titleTrailing = cluster
        shell.onTap = { [weak self] in
            guard let self, let device else { return }
            AndroidPresentation.open(device, on: model)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func configure(device: AndroidDevice, showsVersion: Bool) {
        self.device = device
        name.text = device.name
        let caption = AndroidPresentation.subtitle(for: device, showsVersion: showsVersion)
        subtitle.text = caption
        subtitle.isHidden = caption == nil
        shell.leading = phoneAndroidFamilyMark(device)
        followPending()
    }

    /// The one verb that applies, at REST but quiet: a small solid glyph in the tertiary ink. Tracked
    /// per row for ``PhoneAndroidRunningCard/followPending()``'s reason.
    private func followPending() {
        generation &+= 1
        let generation = generation

        guard let device else { return }
        var isPending = false
        withObservationTracking {
            isPending = self.model.pending.contains(device.key)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.followPending()
                }
            }
        }

        for view in verb.subviews { view.removeFromSuperview() }
        let control: UIView = isPending
            ? phoneAndroidPendingSpinner()
            : SlatePlateVerbButton(
                symbol: .playFill, help: AndroidPresentation.startHelp(device),
                size: Slate.Typeface.footnote, plate: Slate.Metric.heightControl,
                tint: PhoneAndroidInk.color(.tertiary),
            ) { [weak self] in
                guard let self else { return }
                Task { await self.model.boot(device) }
            }
        control.translatesAutoresizingMaskIntoConstraints = false
        verb.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: verb.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: verb.centerYAnchor),
        ])
    }
}
#endif
