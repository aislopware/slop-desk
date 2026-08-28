// PhoneSimulatorDeviceList — the host's devices, drawn in Slate.
//
// This replaced a WKWebView showing the simulator server's own page. The objection was never that the
// page looked wrong: it was that matching it to the theme meant re-scoping its CSS variables AND
// overriding the handful of rules that baked a literal hex, with every server update putting that back
// in play. Drawn natively the question does not arise — the row shell, the section header and the
// search plate are the same ones the navigator uses, so a theme swap repoints this list with
// everything else.
//
// GROUPING is by DEVICE FAMILY, with running devices lifted into their own group above. A device set is
// thirty near-identical strings ("iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max"), and the two
// questions actually asked of this list are "what is running" and "where are the iPads" — so those are
// the two cuts. Sorting inside a family is the server's own order, which is stable across polls; a list
// that reorders itself under the finger is the opposite of what someone tapping Boot wants.
//
// THE TWO GROUPS ARE DRAWN DIFFERENTLY, because only one of them has anything to show. For a device
// that is OFF the server knows four things and three are already on screen; a device that is RUNNING
// has a screen, and that is what ``PhoneSimulatorRunningCard`` draws. The bareness was never a want of
// ornament — it was a want of subject.
//
// AND THE WIDTH IS SPENT ON DEVICES, not on air. Both groups lay out in a grid whose column count
// follows the width, so an iPad in landscape shows more devices rather than longer rows, and a 390pt
// phone falls to the one column that width honestly holds.
//
// EVERY ROW CARRIES ITS ACTION, at rest, not on hover — a small tertiary glyph that steps to the
// primary ink while a pointer is on the row. Drawn at full strength on every row it became a column of
// identical rings down the trailing edge, which is texture, not twelve verbs.
//
// A ROW NEVER REPEATS WHAT ITS HEADING ALREADY SAID — the runtime is lifted into the heading when every
// member shares it (``SimulatorListSection/showsRuntime(_:)``). The family GLYPH is the exception and
// stays on every row and every card: in a grid the last row of the second line is two lines down from
// its heading, and the eye arriving at it has nothing but the name.
//
// ⚠️ THE ITEM IDENTITY IS ``SimulatorListSection/rowIdentities``, NOT THE UDID, and that is the whole
// reason that array exists. A udid is stable across a boot, which is right for "the same device" and
// wrong for "the same row": under a diffable data source a boot would become a MOVE, and the cell
// carrying it would arrive in the running section still built as a row. Section-qualified identities
// make it the delete-and-insert it actually is, which is also the reflow the deleted half animated by
// keying on exactly this value.
//
// A FAILED POLL DRAWS NOTHING HERE (user-directed 2026-08-04). The last-known devices are still the
// best information available; the report goes to the window's notification card like every other report
// this panel makes, and the rows keep saying what they last knew.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhoneSimulatorDeviceList: UIView, UICollectionViewDelegate {
    private let model: SimulatorSidebarModel
    private let onOpen: (String) -> Void

    /// Filters by name and runtime as typed. Deliberately NOT persisted: a filter that survived a panel
    /// close would hide devices with nothing on screen to explain why.
    private var query = ""

    private let field = UIView()
    private let search: SlateSearchLine
    private let clear: UIControl
    private let collection: UICollectionView
    private var source: UICollectionViewDiffableDataSource<String, String>!

    /// The sections as last drawn, and the device behind each row identity. Held because a diffable
    /// data source deals in identifiers and every callback — the cell, the menu, the tap — has to get
    /// back to a device from one.
    private var sections: [SimulatorListSection] = []
    private var devices: [String: SimulatorDevice] = [:]
    private var showsRuntime: [String: Bool] = [:]

    /// The notice that stands in for the whole list: no devices at all, or none matching the query.
    private var notice: UIView?

    /// ⚠️ ONE COUNTER PER FOLLOWER. `[weak self]` stops a chain when the view dies; it does not
    /// SUPERSEDE a live arm, so a second `follow()` while the first is still registered leaves two
    /// chains re-arming on every change, and they multiply rather than replace. Two counters and not
    /// one, because a bump from either follower would otherwise silently unsubscribe the other.
    private var generation = 0
    private var pendingGeneration = 0

    init(model: SimulatorSidebarModel, onOpen: @escaping (String) -> Void) {
        self.model = model
        self.onOpen = onOpen
        search = SlateSearchLine(placeholder: SimulatorPresentation.searchPlaceholder)
        var clearAction: (() -> Void)?
        clear = PhoneDevicePanelChrome.clearKey(ink: Slate.Native.Text.icon) { clearAction?() }
        collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // THE GROUND, like every other column in this window (ONE ISLAND, law 1) — the list sinks.
        backgroundColor = Slate.Native.Surface.field

        clearAction = { [weak self] in
            self?.search.text = ""
            self?.retype("")
        }
        search.onTextChange = { [weak self] text in self?.retype(text) }
        buildField()
        buildCollection()
        refreshClear(animated: false)
        follow()
        followPending()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Filter

    /// The navigator's search plate, verbatim — a field on the hover tint sharing the list's gutter, so
    /// it reads exactly as wide as the rows below it.
    private func buildField() {
        let magnifier = UIImageView()
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.image = UIImage(
            systemName: SFSymbol.magnifyingglass.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )?.withRenderingMode(.alwaysTemplate)
        magnifier.tintColor = Slate.Native.Text.icon
        magnifier.setContentHuggingPriority(.required, for: .horizontal)

        let run = UIStackView(arrangedSubviews: [magnifier, search, clear])
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        run.alignment = .center
        run.spacing = Slate.Metric.space1

        field.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(run)
        field.slateChromeFieldPlate()
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            run.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: Slate.Metric.space2),
            run.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -Slate.Metric.space2),
            run.topAnchor.constraint(equalTo: field.topAnchor),
            run.bottomAnchor.constraint(equalTo: field.bottomAnchor),
        ])
    }

    private func retype(_ text: String) {
        guard text != query else { return }
        let wasEmpty = query.isEmpty
        query = text
        if wasEmpty != text.isEmpty { refreshClear(animated: true) }
        refill()
    }

    /// The key appears on the FIRST keystroke and vanishes on the last; the fade is what keeps it from
    /// reading as part of the typing.
    private func refreshClear(animated: Bool) {
        let wanted: CGFloat = query.isEmpty ? 0 : 1
        guard animated else {
            clear.alpha = wanted
            return
        }
        phoneSimulatorAnimate(Slate.Motion.smallFade) { [clear] in
            clear.alpha = wanted
        }
    }

    // MARK: The list

    private func buildCollection() {
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        collection.delegate = self
        // Taps are the CELLS' — the row shell owns a recogniser of its own and the card carries one, so
        // a selection here would be a second, disagreeing path to the same intent.
        collection.allowsSelection = false
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .onDrag
        collection.setCollectionViewLayout(layout(), animated: false)
        collection.register(
            PhoneSimulatorRunningCard.self,
            forCellWithReuseIdentifier: PhoneSimulatorRunningCard.reuseIdentifier,
        )
        collection.register(
            PhoneSimulatorDeviceRowCell.self,
            forCellWithReuseIdentifier: PhoneSimulatorDeviceRowCell.reuseIdentifier,
        )
        collection.register(
            PhoneSimulatorSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: PhoneSimulatorSectionHeader.reuseIdentifier,
        )
        addSubview(collection)
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Slate.Metric.space2),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        source = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collection,
        ) { [weak self] view, indexPath, identity in
            self?.cell(in: view, at: indexPath, for: identity) ?? UICollectionViewCell()
        }
        source.supplementaryViewProvider = { [weak self] view, kind, indexPath in
            self?.header(in: view, kind: kind, at: indexPath)
        }
    }

    /// The two groups' geometry, resolved per section against the width the panel actually has. Cards
    /// take a FIXED width so one running device is one card and not a card stretched across the panel;
    /// rows SHARE the width, because a row's content is a name and a name is happy to have more room.
    private func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let isRunning = self?.sections[safe: index]?.isRunning ?? false
            let width = environment.container.effectiveContentSize.width
                - 2 * Slate.Metric.space2
            let target = isRunning ? Slate.Metric.deviceCardWidth : Slate.Metric.deviceRowWidth
            let spacing = isRunning ? Slate.Metric.space2 : Slate.Metric.space1
            let columns = Swift.max(1, Int((width + spacing) / (target + spacing)))
            let height: CGFloat = isRunning
                ? Slate.Metric.deviceCardArt + Slate.Metric.heightControl
                + 3 * Slate.Metric.space2
                : Slate.Metric.heightRow

            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(height),
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(height),
                ),
                repeatingSubitem: item, count: columns,
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Slate.Metric.space2,
                bottom: Slate.Metric.space2, trailing: Slate.Metric.space2,
            )
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(Slate.Metric.heightSectionHeader),
                ),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top,
            )]
            return section
        }
    }

    private func cell(
        in view: UICollectionView, at indexPath: IndexPath, for identity: String,
    ) -> UICollectionViewCell {
        // ⚠️ Resolved through the IDENTITY the data source handed over, never by indexing the model's
        // array with the index path: the two agree only until a poll lands between a snapshot and its
        // cells, which is the one moment a stale index is a wrong device rather than a crash.
        guard let device = devices[identity] else { return UICollectionViewCell() }
        if sections[safe: indexPath.section]?.isRunning == true {
            guard let cell = view.dequeueReusableCell(
                withReuseIdentifier: PhoneSimulatorRunningCard.reuseIdentifier, for: indexPath,
            ) as? PhoneSimulatorRunningCard else { return UICollectionViewCell() }
            cell.configure(model: model, device: device) { [weak self] in self?.enter(device.udid) }
            return cell
        }
        guard let cell = view.dequeueReusableCell(
            withReuseIdentifier: PhoneSimulatorDeviceRowCell.reuseIdentifier, for: indexPath,
        ) as? PhoneSimulatorDeviceRowCell else { return UICollectionViewCell() }
        cell.configure(
            model: model, device: device, showsRuntime: showsRuntime[identity] ?? false,
        ) { [weak self] in self?.open(device) }
        return cell
    }

    private func header(
        in view: UICollectionView, kind: String, at indexPath: IndexPath,
    ) -> UICollectionReusableView? {
        guard kind == UICollectionView.elementKindSectionHeader,
              let section = sections[safe: indexPath.section] else { return nil }
        guard let header = view.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: PhoneSimulatorSectionHeader.reuseIdentifier,
            for: indexPath,
        ) as? PhoneSimulatorSectionHeader else { return nil }
        // The group's own CONTROL, offered only once more than one device is up: with one running it
        // is the same tap as that card's own stop button under a longer name.
        header.configure(
            title: section.title, caption: section.runtime,
            shutdownAll: section.isRunning && section.devices.count > 1
                ? (SimulatorPresentation.shutdownAllHelp(section.devices.count), { [model] in
                    Task { await model.shutdownAll() }
                })
                : nil,
        )
        return header
    }

    // MARK: Observation

    /// The list's structure — which devices exist, and therefore which sections and rows. Split from
    /// the pending follower below because they rebuild different things: this one re-snapshots, that
    /// one repaints a plate.
    private func follow() {
        generation &+= 1
        let generation = generation
        var seen: [SimulatorDevice] = []
        withObservationTracking {
            seen = self.model.devices
        } onChange: { [weak self] in
            // The hop is what makes this legal: `onChange` runs INSIDE the mutation, so touching the
            // model or the view tree from it would re-enter the write that woke it. And it fires ONCE,
            // which is why the follower re-registers from inside its own handler.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        refill(seen)
    }

    /// The boot/shutdown fold, pushed into the cells that are on screen. ONE observation for the whole
    /// list rather than one per cell: `pending` changes twice per boot, and a dozen visible cards each
    /// watching it is a dozen wake-ups for one flag.
    private func followPending() {
        pendingGeneration &+= 1
        let generation = pendingGeneration
        var pending: Set<String> = []
        withObservationTracking {
            pending = self.model.pending
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == pendingGeneration else { return }
                    followPending()
                }
            }
        }
        for cell in collection.visibleCells {
            guard let indexPath = collection.indexPath(for: cell),
                  let identity = source.itemIdentifier(for: indexPath),
                  let device = devices[identity] else { continue }
            let isPending = pending.contains(device.udid)
            (cell as? PhoneSimulatorRunningCard)?.showPending(isPending)
            (cell as? PhoneSimulatorDeviceRowCell)?.showPending(isPending)
        }
    }

    /// ⚠️ `matches` is derived ONCE per pass and threaded down. With a query in the box it is a filter
    /// over every device, and the deleted half was answering an emptiness test and then building the
    /// sections from two separate derivations.
    private func refill(_ all: [SimulatorDevice]? = nil) {
        let all = all ?? model.devices
        let shown = SimulatorPresentation.matches(all, query: query)
        if all.isEmpty {
            show(notice: SimulatorPresentation.noDevices)
            return
        }
        if shown.isEmpty {
            show(notice: SimulatorPresentation.noMatches(query))
            return
        }
        show(notice: nil)

        sections = SimulatorDeviceSections.sections(for: shown)
        devices = [:]
        showsRuntime = [:]
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in sections {
            snapshot.appendSections([section.title])
            snapshot.appendItems(section.rowIdentities, toSection: section.title)
            for (slot, identity) in section.rowIdentities.enumerated() {
                guard let device = section.devices[safe: slot] else { continue }
                devices[identity] = device
                showsRuntime[identity] = section.showsRuntime(device)
            }
        }
        // THE REFLOW. A boot is not a row changing colour: the device leaves its family, RUNNING
        // appears above it, and everything under the cut shifts — the one structural change this list
        // ever makes. Animated because the identities carry it; a poll that returns the same devices
        // produces the same identities and animates nothing.
        source.apply(snapshot, animatingDifferences: true)
    }

    /// Rebuilt rather than re-labelled, because the two sentences are not the same view's text: "no
    /// devices" and "nothing matches `foo`" answer different questions and the second one changes with
    /// every keystroke.
    private func show(notice text: String?) {
        notice?.removeFromSuperview()
        notice = nil
        guard let text else {
            collection.isHidden = false
            return
        }
        collection.isHidden = true
        // The snapshot goes with the rows: a hidden list holding a device that is no longer there is a
        // context menu one long press away from acting on it.
        sections = []
        devices = [:]
        showsRuntime = [:]
        source.apply(NSDiffableDataSourceSnapshot<String, String>(), animatingDifferences: false)
        let view = PhoneDevicePanelChrome.notice(text)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: collection.topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        notice = view
    }

    // MARK: Verbs

    /// A tap on a shut-down device BOOTS it — the same intent a tap on a running card carries ("I want
    /// to use this device"), one step earlier. Doing nothing is the behaviour that made the previous
    /// revision feel broken.
    private func open(_ device: SimulatorDevice) {
        guard !model.pending.contains(device.udid) else { return }
        Task { await model.boot(device.udid) }
    }

    private func enter(_ udid: String) {
        onOpen(udid)
    }

    // MARK: The context menu

    func collectionView(
        _: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let identity = source.itemIdentifier(for: indexPath),
              let device = devices[identity] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return phoneSimulatorDeviceMenu(model: model, device: device) { [weak self] in
                self?.enter(device.udid)
            }
        }
    }
}

// MARK: - One shut-down device

/// A row in the grid: the family mark, the name, whatever the heading has not already said, and the one
/// verb that applies.
@MainActor
final class PhoneSimulatorDeviceRowCell: UICollectionViewCell {
    static let reuseIdentifier = "PhoneSimulatorDeviceRowCell"

    private let row = SlateListRowView()
    private let mark = UIView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let spinner = phoneSimulatorPendingSpinner()
    private let boot = SlatePlateVerbButton(
        symbol: .playFill, size: Slate.Typeface.footnote, plate: Slate.Metric.heightControl,
    )
    private var model: SimulatorSidebarModel?
    private var device: SimulatorDevice?

    override init(frame: CGRect) {
        super.init(frame: frame)
        mark.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: Slate.Typeface.base)
        title.textColor = Slate.Native.Text.primary
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: Slate.Typeface.footnote)
        subtitle.textColor = Slate.Native.Text.tertiary
        subtitle.numberOfLines = 1
        // The subtitle is what gives way first — a squeezed row keeps its NAME and its verb.
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        boot.addAction(UIAction { [weak self] _ in
            guard let self, let model, let device else { return }
            Task { await model.boot(device.udid) }
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            spinner.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            mark.widthAnchor.constraint(equalToConstant: Slate.Metric.deviceMarkWidth),
            mark.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])

        // Both in the trailing CLUSTER, not one of them in the shell's hover overlay: that overlay is
        // for an affordance the meta fades out to make room for, and this action never fades. Laid out
        // side by side they cannot collide — the first cut put the button over the runtime and drew a
        // play glyph through the word "iOS".
        let cluster = UIStackView(arrangedSubviews: [subtitle, spinner, boot])
        cluster.translatesAutoresizingMaskIntoConstraints = false
        cluster.axis = .horizontal
        cluster.alignment = .center
        cluster.spacing = Slate.Metric.space1

        row.leading = mark
        row.title = title
        row.titleTrailing = cluster
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func configure(
        model: SimulatorSidebarModel, device: SimulatorDevice, showsRuntime: Bool,
        onTap: @escaping () -> Void,
    ) {
        self.model = model
        self.device = device
        title.text = device.name
        let caption = SimulatorPresentation.rowSubtitle(device, showsRuntime: showsRuntime)
        subtitle.text = caption
        subtitle.isHidden = caption == nil
        boot.help = SimulatorPresentation.bootHelp(device)
        row.onTap = onTap

        for old in mark.subviews { old.removeFromSuperview() }
        let glyph = phoneSimulatorFamilyMark(device)
        mark.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: mark.leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
        ])
        showPending(model.pending.contains(device.udid))
    }

    /// The two occupy the SAME slot and cross-fade rather than replace each other. Both are
    /// `heightControl` square, so the row does not move; what would move without the fade is the eye,
    /// because a glyph becoming a spinner in one frame reads as a redraw rather than as the tap being
    /// accepted — and accepting the tap is the whole of what the spinner is there to say.
    func showPending(_ isPending: Bool) {
        guard spinner.isHidden == isPending else { return }
        phoneSimulatorAnimate(Slate.Motion.smallFade) { [spinner, boot] in
            spinner.isHidden = !isPending
            boot.isHidden = isPending
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.onTap = nil
        model = nil
        device = nil
    }
}

// MARK: - A group's heading

/// The group's title, with its shared runtime as the heading's own CAPTION rather than as a trailing
/// accessory: the heading is taxonomy, so the runtime joins it as taxonomy, beside the word it
/// qualifies rather than at the panel's far edge. The far edge is where the group's own CONTROL goes.
@MainActor
final class PhoneSimulatorSectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "PhoneSimulatorSectionHeader"

    private let header = SlateSectionHeaderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            // Nudged onto the ROWS' left rail: the shared header insets by `space2` and a list row by
            // `space3`, and four points of disagreement between two things meant to line up reads as
            // "off" without anyone locating why.
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func configure(title: String, caption: String?, shutdownAll: (help: String, run: () -> Void)?) {
        header.title = title
        header.caption = caption
        guard let shutdownAll else {
            header.accessory = nil
            return
        }
        let plate = SlatePlateVerbButton(
            symbol: .stopCircle, help: shutdownAll.help, size: Slate.Typeface.footnote,
            plate: Slate.Metric.heightControl, tint: Slate.Native.Text.tertiary,
            action: shutdownAll.run,
        )
        header.accessory = plate
    }
}

// MARK: - Bounds-checked indexing

/// ⚠️ FILE-PRIVATE on purpose. A layout section provider and a supplementary provider are both called
/// for index paths the snapshot may already have moved past, so an out-of-range read here is an
/// ordinary race rather than a bug worth trapping on — but `Array` is everyone's type, and a
/// module-wide `subscript(safe:)` is exactly the kind of extension two files in one target each declare
/// and then fail to build.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
