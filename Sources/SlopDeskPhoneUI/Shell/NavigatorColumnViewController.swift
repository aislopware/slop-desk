// NavigatorColumnViewController — the leading column: the project groups and their panes.
//
// A flat tabs panel on the `Slate.Surface.field` chrome floor (NOT a system sidebar material — the
// same choice ``MacNavigatorColumn`` makes and for the same reason: this is a flat tabs panel on the
// authored ground, and platform vibrancy underneath it would tint every ink judged against that
// ground), a header SEARCH FIELD spanning the full row width with the new-tab `+` beside it, and rows
// grouped into By-Project sections under a folder + NAME header.
//
// ⚠️ THE HIERARCHY IS PROJECT → PANE, and the skeleton this file replaced said "sessions → tabs →
// panes". There is no session level and no tab level in the rail's model: ``RailRowsBuilder`` emits
// ONE ``RailRow`` per PANE (`id: PaneID`), and ``SidebarSections/sections(_:tabOrder:query:)`` buckets
// those rows by their By-Project key — a split tab's two panes bucket into their OWN projects, which
// is precisely why the tab is not a level. The tab survives only as `row.tabID`, which the rename
// verb addresses.
//
// ⚠️ THERE IS NO DRAG REORDER, and its absence is a DECISION rather than a gap. The skeleton asked for
// `reorderingHandlers`, on the grounds that the SwiftUI `List.onMove` landed a frame late — but the
// deleted SwiftUI half has no `.onMove` and never had one, and there is no store verb to commit a
// move to. `WorkspaceStore+TabOrdering` states the law: "There is no client-side grouping/sorting,
// recency stamps, manual drag-reorder, or git-toplevel sweep — the key is HOST-pushed (wire type 34)
// so every reconnect converges on the same sections regardless of client-side state."
// `docs/DECISIONS.md` records the `.manual` drag-reorder's removal and re-affirms it. A reordering
// handler here would be a gesture with nowhere to land.
//
// WHAT IS NOT DECIDED HERE, and the reason the column is thin: the row's whole appearance
// (``SidebarRowPresentation/reading(for:store:fallbackTitle:)`` → ``SidebarRowReading``, read by
// ``NavigatorRowCell``), the git dialect (``SidebarGitLine``, measured by ``SidebarGitLineView``), the
// sectioning (``SidebarSections``), the menu's verb table (``SidebarRowMenu``) and the select path
// (``SidebarSelection``) are all `SlopDeskClientCore`'s, cut once and read by both platforms. What is
// left in this file is layout, gestures and the snapshot.
//
// WHAT THE DIFFABLE DATA SOURCE BUYS, which is docs/62 §3.4's whole argument for it on this surface:
// the rail is unbounded and LIVE-FILTERED, so a keystroke in the search field is a diff rather than a
// teardown, and a row that survives the filter keeps its cell — its spinner, its rename field, its
// scroll position. THE IDENTIFIER IS THE ID, NEVER THE RENDERED CONTENT: the item is a `PaneID`, so a
// pane's status tick does not re-diff the list, it repaints one leaf (``NavigatorRowCell/follow()``).
//
// FOUR POINTER→THUMB RE-LAYOUTS, each one the deleted SwiftUI half had already made:
//
//   1. The git line is the HEADER CELL's second line over the same ``SidebarGitLine`` runs.
//   2. ``SidebarRowReading/presence`` is the row's second line; the rest of the tooltip rides
//      `accessibilityHint`.
//   3. The close × is a trailing SWIPE (`allowsFullSwipe: false`) → ``WorkspaceStore/requestClosePaneTree(_:)``,
//      not a hover swap.
//   4. The disclosure is `UICellAccessory.outlineDisclosure` over an
//      ``NSDiffableDataSourceSectionSnapshot``, keyed by ``SidebarSections/collapseKey(_:)`` into a
//      session-scoped `Set<String>` — the direct descendant of `Section(isExpanded:)`.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

/// One thing the list can show. The header carries the section's COLLAPSE KEY and the row carries its
/// pane's id — both stable across a filter keystroke, which is the whole contract.
enum NavigatorItem: Hashable {
    case header(String)
    case row(PaneID)
}

@MainActor
final class NavigatorColumnViewController: UIViewController, UICollectionViewDelegate {
    private let store: WorkspaceStore

    /// The memoized row model: the column reads its rows from HERE so a settled tree registers NO
    /// Observation dependency on the store's volatile per-pane dicts. A status / git / progress tick
    /// then repaints only the cheap row and header leaves (which read their own pane's chrome live),
    /// never the whole rows + sectioning + snapshot pass.
    private let rowsMemo = RailRowsMemo()

    /// The transient search query — narrows the rows through the SAME pure `RailRowsBuilder.filtered`
    /// the deleted `.searchable` rode. Session-scoped, never persisted.
    private var query = ""

    /// The COLLAPSED project groups, keyed by ``SidebarSections/collapseKey(_:)``. Session-scoped
    /// presentation state — a fresh launch opens every group.
    private var collapsed: Set<String> = []

    /// The tracked read's generation — see ``follow()``.
    private var generation = 0

    /// The last reconciled model, kept so a collection-view callback can answer WHICH ROW an item
    /// identifier names. ⚠️ Resolution goes identifier → here, NEVER `indexPath.item` into an array:
    /// a live filter moves rows under an index path the run loop has not caught up with yet
    /// (docs/62 §4 hazard 3).
    private var rowsByID: [PaneID: RailRow] = [:]
    private var sectionsByKey: [String: SidebarSection] = [:]

    private let plate = UIView()
    private let magnifier = UIImageView()
    private let search = SlateSearchLine(placeholder: "Search tabs")
    private let clear = UIButton(type: .system)
    private let add = UIButton(type: .system)
    private let empty = UILabel()
    /// Minted with a PLACEHOLDER layout: the list configuration is assembled in ``buildList()``, which
    /// swaps the real one in before the first pass.
    private let collection = UICollectionView(
        frame: .zero, collectionViewLayout: UICollectionViewLayout(),
    )
    private var dataSource: UICollectionViewDiffableDataSource<String, NavigatorItem>?

    /// The two registrations, named because the generic pair is the whole of each one's opening line —
    /// spelled inline it leaves no room for the closure's parameters beside the brace.
    private typealias RowRegistration = UICollectionView.CellRegistration<NavigatorRowCell, PaneID>
    private typealias HeaderRegistration =
        UICollectionView.CellRegistration<NavigatorSectionHeaderCell, String>

    /// ⚠️ `chrome` and `overlay` ARE THE SHELL'S CONTRACT, NOT THIS COLUMN'S BUSINESS, and they are
    /// taken and dropped rather than stored so that stays legible. `WorkspaceChromeState` owns whether
    /// this column is COLLAPSED, which is the split controller's question and not the list's; the
    /// summoned overlays are raised from the shell and from the pane, never from a rail row — the row
    /// menu's every entry is a ``SidebarRowMenu`` verb against the store. A stored-but-unread handle
    /// would read as a wiring someone forgot to finish.
    init(store: WorkspaceStore, chrome _: WorkspaceChromeState, overlay _: OverlayCoordinator) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: The column's chrome

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
        buildSearchRow()
        buildList()
        layOut()
        // A `CGColor` is FLAT — it does not follow a theme flip on its own, and the search plate keeps
        // two of them. `registerForTraitChanges`, never `traitCollectionDidChange`: the override is
        // deprecated on this deployment target and banned in this tree.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (column: Self, _: UITraitCollection) in
            column.paint()
        }
        paint()
        follow()
    }

    /// The header row IS the search bar (the deleted SwiftUI half's `.searchable`, and the Mac's own
    /// header row): a quiet inset field on the hover tint, filtering the rows below. Clearing is one
    /// tap; the ⓧ appears only while a query is live. Beside it stands the `+`, which was the SwiftUI
    /// toolbar's `.primaryAction` — this column has no navigation bar to hang it in, and the search
    /// row is the only chrome above the list.
    ///
    /// ⚠️ A HAND-BUILT PLATE, NOT `UISearchController`. ``SlateSearchLine``'s own documentation names
    /// this row as one of its three callers and states the division: the field is the text LINE and
    /// the caller owns the plate. A search controller would bring its own bar, its own metrics and its
    /// own material, none of which are on the Slate ladder.
    private func buildSearchRow() {
        plate.layer.cornerRadius = Slate.Metric.radiusControl
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = Slate.Metric.hairline
        plate.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plate)

        magnifier.contentMode = .center
        magnifier.isAccessibilityElement = false
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(magnifier)

        search.onTextChange = { [weak self] text in
            guard let self else { return }
            query = text
            clear.isHidden = text.isEmpty
            follow()
        }
        plate.addSubview(search)

        clear.isHidden = true
        clear.accessibilityLabel = "Clear search"
        clear.addAction(UIAction { [weak self] _ in self?.clearQuery() }, for: .touchUpInside)
        clear.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(clear)

        add.accessibilityLabel = "New Tab"
        add.addAction(
            UIAction { [weak self] _ in self?.store.newTerminalPane(.newTab) }, for: .touchUpInside,
        )
        add.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(add)
    }

    private func buildList() {
        // `.sidebarPlain`, not `.plain`: it is the appearance that indents an outline's children under
        // their disclosure without drawing the inset-grouped card the rail is not.
        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebarPlain)
        // The column paints the ground; the list stands on it. A list background here would be the
        // system's, which is the one thing this column refuses.
        configuration.backgroundColor = .clear
        // No separators: the rows are cards, and a rule between two cards reads as a third surface.
        configuration.showsSeparators = false
        // ⚠️ `.none`, NOT `.firstItemInSection`. A section with no project key has no header item at
        // all (the ungrouped bucket), and `.firstItemInSection` would render that section's FIRST PANE
        // as a header. The outline comes from the section snapshot's parent/child shape plus the
        // header cell's own `.outlineDisclosure` accessory, which needs no header mode.
        configuration.headerMode = .none
        // `assumeIsolated` is the ASSERTION, not a hop: a list layout's swipe provider is already
        // delivered on the main actor, and saying so is what lets it reach a `@MainActor` column.
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            MainActor.assumeIsolated { self?.closeSwipe(at: indexPath) }
        }
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)

        collection.setCollectionViewLayout(layout, animated: false)
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .onDrag
        collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collection)

        let rowCell = RowRegistration { [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            cell.configure(
                row: row, store: store,
                fallbackTitle: PaneChooserRegistry.option(for: row.kind).title,
            )
        }
        let headerCell = HeaderRegistration { [weak self] cell, _, key in
            guard let self, let section = sectionsByKey[key] else { return }
            cell.configure(
                title: section.header ?? "", projectKey: section.projectKey, rows: section.rows,
                collapsed: collapsed.contains(key), store: store,
            )
        }
        dataSource = UICollectionViewDiffableDataSource<String, NavigatorItem>(
            collectionView: collection,
        ) { view, indexPath, item in
            switch item {
            case let .header(key):
                view.dequeueConfiguredReusableCell(using: headerCell, for: indexPath, item: key)
            case let .row(id):
                view.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: id)
            }
        }
        // The user's own fold, recorded where it outlives every cell. The handlers fire for the
        // GESTURE only, so the set and the applied snapshot cannot drift: a programmatic collapse goes
        // through ``collapsed`` first and the snapshot follows it.
        dataSource?.sectionSnapshotHandlers.willCollapseItem = { [weak self] item in
            guard case let .header(key) = item else { return }
            self?.fold(key, collapsed: true)
        }
        dataSource?.sectionSnapshotHandlers.willExpandItem = { [weak self] item in
            guard case let .header(key) = item else { return }
            self?.fold(key, collapsed: false)
        }

        // The zero-state line stands exactly where the row titles would — the rows' text rail.
        empty.font = .systemFont(ofSize: Slate.Typeface.base)
        empty.textColor = Slate.Native.Text.secondary
        empty.numberOfLines = 0
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
    }

    private func layOut() {
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: safe.topAnchor, constant: Slate.Metric.space2),
            plate.leadingAnchor.constraint(
                equalTo: safe.leadingAnchor, constant: Slate.Metric.space3,
            ),
            plate.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),

            add.leadingAnchor.constraint(equalTo: plate.trailingAnchor, constant: Slate.Metric.space2),
            add.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Slate.Metric.space3),
            add.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            // The full thumb target, on a control whose glyph is `footnote`-sized.
            add.widthAnchor.constraint(equalToConstant: Slate.Metric.heightRowTall),
            add.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRowTall),

            magnifier.leadingAnchor.constraint(
                equalTo: plate.leadingAnchor, constant: Slate.Metric.space2,
            ),
            magnifier.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            search.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space1,
            ),
            search.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            search.trailingAnchor.constraint(
                equalTo: clear.leadingAnchor, constant: -Slate.Metric.space1,
            ),
            clear.trailingAnchor.constraint(
                equalTo: plate.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            clear.centerYAnchor.constraint(equalTo: plate.centerYAnchor),

            // `space3` between the field and the first group, not a breath: a header starting just
            // under the search plate reads as if the field were part of the first group.
            collection.topAnchor.constraint(
                equalTo: plate.bottomAnchor, constant: Slate.Metric.space3,
            ),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            empty.topAnchor.constraint(equalTo: collection.topAnchor, constant: 6),
            empty.leadingAnchor.constraint(
                equalTo: safe.leadingAnchor, constant: Slate.Metric.tabRowInset,
            ),
            empty.trailingAnchor.constraint(
                equalTo: safe.trailingAnchor, constant: -Slate.Metric.tabRowInset,
            ),
        ])
    }

    /// Every dynamic ink this controller stamps into a `CALayer` or a `UIImage`, re-resolved for the
    /// live trait collection.
    private func paint() {
        plate.backgroundColor = Slate.Native.State.hover
        plate.layer.borderColor = Slate.Native.Line.field.resolvedColor(with: traitCollection).cgColor
        let icon = UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: .regular)
        magnifier.image = UIImage(systemName: "magnifyingglass", withConfiguration: icon)?
            .withTintColor(Slate.Native.Text.icon, renderingMode: .alwaysOriginal)
        clear.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: icon)?
                .withTintColor(Slate.Native.Text.icon, renderingMode: .alwaysOriginal),
            for: .normal,
        )
        add.setImage(
            UIImage(systemName: "plus", withConfiguration: icon)?
                .withTintColor(Slate.Native.Text.primary, renderingMode: .alwaysOriginal),
            for: .normal,
        )
    }

    // MARK: The live rebuild

    /// Re-derive the sections and reconcile the snapshot against them, re-arming for the next
    /// STRUCTURAL change. Volatile chrome never reaches here: the rows and headers read their own.
    ///
    /// ⚠️ `withObservationTracking` FIRES ONCE, so the re-arm IS the subscription and EVERY tracked
    /// read has to sit INSIDE the closure — hoisting `store.flatOrderedTabIDs()` to a `let` above
    /// would silently unsubscribe from tab order and leave the sections stale on exactly that input.
    /// The generation counter is how a stale arm is superseded: a search keystroke calls `follow()`
    /// again, and the arm made before it finds a moved counter and returns without re-arming.
    private func follow() {
        generation &+= 1
        let generation = generation
        var rows: [RailRow] = []
        var order: [TabID] = []
        withObservationTracking {
            rows = rowsMemo.rows(for: store)
            order = store.flatOrderedTabIDs()
        } onChange: { [weak self] in
            // ⚠️ `onChange` runs INSIDE the mutation, BEFORE the store's write lands, so the next read
            // is SCHEDULED rather than run inline — a read inside the callback sees the OLD value and
            // paints one frame stale.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        reconcile(rows: rows, tabOrder: order)
    }

    private func reconcile(rows: [RailRow], tabOrder: [TabID]) {
        let sections = SidebarSections.sections(rows, tabOrder: tabOrder, query: query)
        rowsByID = Dictionary(
            sections.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first },
        )
        sectionsByKey = Dictionary(
            sections.map { (SidebarSections.collapseKey($0.projectKey), $0) },
            uniquingKeysWith: { first, _ in first },
        )

        if let line = SidebarSections.emptyLine(rows: rows, sections: sections) {
            empty.text = line
            empty.isHidden = false
        } else {
            empty.isHidden = true
        }

        let keys = sections.map { SidebarSections.collapseKey($0.projectKey) }
        let animate = (dataSource?.snapshot().numberOfItems ?? 0) > 0
        alignSections(to: keys)

        for section in sections {
            let key = SidebarSections.collapseKey(section.projectKey)
            var snapshot = NSDiffableDataSourceSectionSnapshot<NavigatorItem>()
            let items = section.rows.map { NavigatorItem.row($0.id) }
            if section.header == nil {
                // The ungrouped bucket: no project, so no header, so no fold — its rows are the
                // section's roots. The Mac draws no bed for it for the same reason.
                snapshot.append(items)
            } else {
                let header = NavigatorItem.header(key)
                snapshot.append([header])
                snapshot.append(items, to: header)
                if !collapsed.contains(key) { snapshot.expand([header]) }
            }
            dataSource?.apply(snapshot, to: key, animatingDifferences: animate)
        }
    }

    /// Bring the data source's SECTION list to `keys`, and touch it ONLY when that list actually
    /// moved — which on this rail is a project appearing, leaving, or being filtered away, never a
    /// keystroke that merely narrows the rows inside sections that all survive.
    ///
    /// ⚠️ THE GUARD IS THE WHOLE POINT, because the apply itself is a TEARDOWN. A top-level snapshot
    /// carries no items, so applying one empties every section and the per-section applies that follow
    /// re-insert the rows as brand-new cells — the running spinner, the open rename field and the
    /// scroll offset all restart. The obvious fix, mutating `dataSource.snapshot()` in place, is
    /// WORSE: a data source driven by section snapshots vends its state FLATTENED, so applying that
    /// snapshot back would erase the outline's parent/child shape and with it every disclosure. So the
    /// hierarchy is only ever written by ``NSDiffableDataSourceSectionSnapshot``, and this pays a
    /// rebuild on the rare edge rather than corrupting the common one.
    private func alignSections(to keys: [String]) {
        guard let dataSource, dataSource.snapshot().sectionIdentifiers != keys else { return }
        var top = NSDiffableDataSourceSnapshot<String, NavigatorItem>()
        top.appendSections(keys)
        dataSource.apply(top, animatingDifferences: false)
    }

    /// Record the user's fold and re-read the header, which changes what it SHOWS: the git line folds
    /// away and the hidden-row count takes the trailing slot, wearing the roll-up ink of the rows it
    /// hides. The snapshot's own expand/collapse is UIKit's to animate — this only reconfigures.
    /// ⚠️ THE HEADER IS RE-CONFIGURED DIRECTLY, not through a snapshot. `reconfigureItems` lives on the
    /// TOP-LEVEL snapshot, and this data source's top-level snapshot is FLATTENED — applying one back
    /// would erase the outline. The section snapshot, which does carry the hierarchy, has no
    /// reconfigure at all. One visible cell, reached by its identifier's index path, is the honest
    /// spelling of "this one header now says something different".
    ///
    /// The hop is the `willCollapse`/`willExpand` contract: the handler fires BEFORE the fold lands,
    /// so a re-read taken inline would still see the old shape.
    private func fold(_ key: String, collapsed isCollapsed: Bool) {
        if isCollapsed { collapsed.insert(key) } else { collapsed.remove(key) }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let section = sectionsByKey[key],
                      let path = dataSource?.indexPath(for: .header(key)),
                      let cell = collection.cellForItem(at: path) as? NavigatorSectionHeaderCell
                else { return }
                cell.configure(
                    title: section.header ?? "", projectKey: section.projectKey, rows: section.rows,
                    collapsed: collapsed.contains(key), store: store,
                )
            }
        }
    }

    // MARK: The search field

    private func clearQuery() {
        search.text = ""
        query = ""
        clear.isHidden = true
        follow()
    }

    // MARK: The list's gestures

    /// The close ×'s thumb form. `allowsFullSwipe` OFF on purpose: closing a pane tree is destructive
    /// and irreversible, and a full swipe fires it on a gesture the user cannot take back mid-flight.
    private func closeSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // Hazard 3: resolve through the data source, never `indexPath.item` into a stored array.
        guard let item = dataSource?.itemIdentifier(for: indexPath), case let .row(id) = item else {
            return nil
        }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.store.requestClosePaneTree(id)
            done(true)
        }
        close.image = UIImage(systemName: "xmark")
        close.backgroundColor = Slate.Native.Status.err
        let configuration = UISwipeActionsConfiguration(actions: [close])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func collectionView(
        _: UICollectionView, shouldSelectItemAt indexPath: IndexPath,
    ) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        // A header's tap is its DISCLOSURE's, not a selection — the whole cell is the fold toggle.
        if case .header = item { return false }
        return true
    }

    func collectionView(_ view: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource?.itemIdentifier(for: indexPath), case let .row(id) = item else {
            return
        }
        // The collection's own selection is DROPPED: the row reads `active` off the store itself
        // (``NavigatorRowCell/follow()``), so leaving a second highlight behind would light two rows
        // whenever focus moved anywhere but here.
        view.deselectItem(at: indexPath, animated: false)
        SidebarSelection.select(id, in: store)
    }

    /// The row's verb table and the header's one verb, both values from below. `indexPaths.count == 1`
    /// is the only shape this list produces: multi-select is off.
    func collectionView(
        _: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let item = dataSource?.itemIdentifier(for: indexPaths[0]) else {
            return nil
        }
        // ⚠️ THE MENU IS BUILT HERE AND THE PROVIDER ONLY HANDS IT OVER. The provider runs later, when
        // the long press resolves, and the store reads that decide a verb's presence and a toggle's
        // state have to be the ones taken at the GESTURE — the same rule ``SlateFactLine`` states for
        // the same closure.
        let elements: [UIMenuElement]
        switch item {
        case let .header(key):
            guard let projectKey = sectionsByKey[key]?.projectKey else { return nil }
            elements = [UIAction(title: "Refresh Git Status") { [weak self] _ in
                self?.store.refreshGitSummary(forProject: projectKey)
            }]
        case let .row(id):
            guard let row = rowsByID[id] else { return nil }
            elements = rowMenu(row)
        }
        guard !elements.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: elements)
        }
    }

    /// One row's menu, spelled from ``SidebarRowMenu/entries(for:store:)``. The `.separator` entries
    /// become NESTED inline menus, which is UIKit's only way to say "a rule goes here" — an
    /// `NSMenu.separator()` has no `UIMenu` equivalent.
    private func rowMenu(_ row: RailRow) -> [UIMenuElement] {
        var groups: [[UIMenuElement]] = [[]]
        for entry in SidebarRowMenu.entries(for: row.id, store: store) {
            switch entry {
            case .separator:
                groups.append([])
            case let .action(verb):
                groups[groups.count - 1].append(UIAction(title: verb.title) { [weak self] _ in
                    guard let self else { return }
                    SidebarRowMenu.run(verb, row: row, store: store)
                })
            case let .toggle(flag, isOn):
                let action = UIAction(title: flag.title) { [weak self] _ in
                    guard let self else { return }
                    SidebarRowMenu.flip(flag, paneID: row.id, store: store)
                }
                action.state = isOn ? .on : .off
                groups[groups.count - 1].append(action)
            }
        }
        return groups
            .filter { !$0.isEmpty }
            .map { UIMenu(title: "", options: .displayInline, children: $0) }
    }
}
#endif
