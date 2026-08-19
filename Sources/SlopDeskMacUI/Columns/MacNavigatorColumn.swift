// MacNavigatorColumn — the left sidebar, in AppKit.
//
// A flat tabs panel on the `Slate.Surface.field` chrome floor (NOT native `.sidebar` vibrancy — the
// host split item is a PLAIN item, so this column paints its own ground), a header SEARCH FIELD
// spanning the full row width, and rows ALWAYS grouped into By-Project islands under a
// gutter-chevron + NAME header that shares ONE left rail with its rows. The top strip is reserved for
// the traffic lights under the hidden titlebar.
//
// WHY THIS COLUMN IS THE ONE docs/56 NAMES AS MAC-SHAPED: forty rows under a mouse, each with a hover
// swap, a drop ring, a context menu, an inline field and a mark that ticks at display rate — the case
// where SwiftUI's "the body is a function of state" costs a whole-list diff per pane heartbeat and
// AppKit's costs one leaf's `needsDisplay`. Everything the two frameworks could disagree about was
// lifted out first: the ROW's reading (``SidebarRowReading``), the GIT dialect (``SidebarGitLine``),
// the SECTIONS (``SidebarSections``), the menu's verb table and the select path
// (``SidebarSelection``). What is left here is drawing and events.
//
// THREE THINGS THIS FILE OWNS THAT NOTHING BELOW COULD:
//
//   1. THE TRAVELLING PLATE. Selection is ONE plate that moves between the rows of a project island
//      and IGNITES in place when it arrives from another (user-directed 2026-08-10). SwiftUI got this
//      from `matchedGeometryEffect` inside a per-island namespace; here the island owns a `CALayer`
//      and animates its own frame, which is the same rule stated directly.
//   2. THE BEDS ARE DEALT FOR THE WHOLE COLUMN AT ONCE. A group whose basename hashes onto the island
//      above it is re-dealt, and only something holding the whole ordered run can know that
//      (``Slate/ProjectTint/Deal``). A headerless section deals as KEYLESS: it draws no bed, so it
//      must neither consume an identity nor constrain the group under it.
//   3. THE MODAL POINTER SHIELD (``MacModalShield``, shared with the content column). A card floating
//      over this column does NOT occlude its hover tracking, so the rows lit their hover plates while
//      the pointer was on the palette. Going hit-test deaf makes hover obey the same occlusion the
//      card's dismiss floor already imposes on clicks.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskVideoProtocol // AgentPreferences — the `preventSleep` flag the row menu toggles
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

@MainActor
final class MacNavigatorColumn: NSViewController, NSTextFieldDelegate {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let onConnect: () -> Void
    private let preferences: PreferencesStore?
    private let paneDrag: PaneDragCoordinator?
    private let overlay: OverlayCoordinator?

    /// The memoized row model: the column reads its rows from HERE so a settled tree registers NO
    /// Observation dependency on the store's volatile per-pane dicts. A status / git / progress tick
    /// then repaints only the cheap row and header leaves (which read their own pane's chrome live),
    /// never the whole rows + sectioning + island-rebuild pass.
    private let rowsMemo = RailRowsMemo()

    /// The transient sidebar search query — narrows the rows through the SAME pure
    /// ``RailRowsBuilder/filtered`` the phone's `.searchable` rides. Session-scoped, never persisted.
    private var query = ""

    /// The COLLAPSED project groups, keyed by ``SidebarSections/collapseKey(_:)``. Session-scoped
    /// presentation state — a fresh launch opens every group.
    private var collapsed: Set<String> = []

    private let search = SlateNativeSearchField.makeConfiguredField(text: "", delegate: nil)
    private let magnifier = NSImageView()
    private let clear = NSButton()
    private let plate = NSView()
    private let scroll = NSScrollView()
    private let islands = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private var newTabSlot: MacNewTabDropSlot?
    private let foot = NSStackView()

    /// The islands currently mounted, in render order — kept so an unchanged section updates in place
    /// (and keeps its plate, its hover and its scroll position) instead of being rebuilt.
    private var mounted: [String: MacSidebarIslandView] = [:]

    init(
        store: WorkspaceStore, connection: AppConnection, onConnect: @escaping () -> Void,
        preferences: PreferencesStore?, paneDrag: PaneDragCoordinator?, overlay: OverlayCoordinator?,
    ) {
        self.store = store
        self.connection = connection
        self.onConnect = onConnect
        self.preferences = preferences
        self.paneDrag = paneDrag
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let root = MacModalShield(overlay: overlay)
        // A theme flip does not follow a `CGColor` — every layer ink this controller stamps has to be
        // re-resolved when the effective appearance changes, and the VIEW is what hears about it.
        root.onAppearanceChange = { [weak self] in self?.paint() }
        root.wantsLayer = true
        view = root
    }

    // MARK: The column's chrome

    override func viewDidLoad() {
        super.viewDidLoad()
        buildSearchRow()
        buildList()
        buildFoot()
        layOut()
        refresh()
    }

    /// The header row IS the search bar (user-directed 2026-08-03 — it replaced the caps "TABS" label
    /// AND its trailing groups menu, both user-retired): a quiet inset field on the hover tint,
    /// filtering the rows below. Clearing is one click; the ⓧ appears only while a query is live.
    /// Full-row width — the field shares the LIST's gutter, so it reads as wide as the tab cards under
    /// it, and the band's status rollup above ends on the same line.
    private func buildSearchRow() {
        plate.wantsLayer = true
        plate.layer?.cornerRadius = Slate.Metric.radiusControl
        plate.layer?.cornerCurve = .continuous
        plate.layer?.borderWidth = Slate.Metric.hairline
        plate.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plate)

        magnifier.imageScaling = .scaleNone
        magnifier.setAccessibilityElement(false)
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(magnifier)

        search.delegate = self
        search.placeholderAttributedString = NSAttributedString(
            string: "Search tabs",
            attributes: [
                .foregroundColor: Slate.Native.Text.tertiary,
                .font: NSFont.systemFont(ofSize: Slate.Typeface.footnote),
            ],
        )
        search.textColor = Slate.Native.Text.primary
        search.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(search)

        clear.isBordered = false
        clear.bezelStyle = .inline
        clear.imagePosition = .imageOnly
        clear.title = ""
        clear.target = self
        clear.action = #selector(clearQuery)
        clear.isHidden = true
        clear.toolTip = "Clear search"
        clear.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(clear)
    }

    private func buildList() {
        // `space2` between islands, not a 2pt row gap: the beds ARE the grouping now, and two beds a
        // hairline apart would read as one striped surface.
        islands.orientation = .vertical
        islands.alignment = .leading
        islands.spacing = Slate.Metric.space2
        islands.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: Slate.Typeface.base)
        empty.textColor = Slate.Native.Text.secondary
        empty.isHidden = true

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(islands)
        document.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // Scrollbars stay invisible for the flat sidebar look.
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.alphaValue = 0
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            islands.topAnchor.constraint(equalTo: document.topAnchor),
            islands.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            islands.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            islands.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            // The zero-state line stands exactly where the row titles would — the rows' text rail.
            empty.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            empty.leadingAnchor.constraint(
                equalTo: document.leadingAnchor, constant: Slate.Metric.tabRowInset,
            ),
        ])

        // Whatever the pane drag needs to hit-test this list: the VIEWPORT rect (a row scrolled out of
        // sight must not count as a drop target) and the scroll view itself (so a drag parked at the
        // list's top or bottom edge scrolls rows into reach).
        if let paneDrag {
            paneDrag.register(.sidebarList) { [weak scroll] in
                guard let scroll, let window = scroll.window else { return nil }
                return window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            }
            paneDrag.sidebarScrollProvider = { [weak scroll] in scroll }
        }
    }

    /// THE CONNECTION ISLAND, anchored to this column's foot (user-directed 2026-08-09).
    ///
    /// It is the LAST BED in a column of beds — same tint family, same corner, same gutter as the
    /// project islands above it — which is what earns it the sidebar's most permanent slot: it is not
    /// a status widget bolted under a list, it is the list's final member, and the one whose subject is
    /// the machine the rest of them run on.
    ///
    /// The air the island needs is ABOVE it, not inside it: `space3` separates it from the last
    /// project bed by more than the `space2` that separates two projects, so it reads as the column's
    /// foot rather than as one more group.
    private func buildFoot() {
        foot.orientation = .vertical
        foot.alignment = .leading
        foot.spacing = 0
        foot.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space3, left: 0, bottom: 0, right: 0,
        )
        foot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(foot)

        let island = MacConnectionIsland(
            store: store, connection: connection, onConnect: onConnect, layout: .stacked,
        )
        foot.addArrangedSubview(island)
        island.widthAnchor.constraint(equalTo: foot.widthAnchor).isActive = true
    }

    private func layOut() {
        let gutter = RailStatusRollupMount.columnGutter
        NSLayoutConstraint.activate([
            // The traffic-light strip — the band the lights stand in. Its LEADING half is bare: the
            // sidebar toggle that used to sit there is mounted at WINDOW level now, because THIS
            // column TRAVELS (the split animates its width on a collapse) and a button parked in it
            // slid under the traffic lights every time it was clicked. The TRAILING end is bare for
            // the same reason and is NOT empty — the band's status rollup stands over this spot,
            // mounted at window level, parking its trailing edge on this column's gutter.
            plate.topAnchor.constraint(equalTo: view.topAnchor, constant: Slate.Metric.titlebarHeight),
            plate.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: gutter),
            plate.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -gutter),
            plate.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),

            magnifier.leadingAnchor.constraint(
                equalTo: plate.leadingAnchor, constant: Slate.Metric.space2,
            ),
            magnifier.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            search.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space1,
            ),
            search.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -Slate.Metric.space1),
            clear.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -Slate.Metric.space2),
            clear.centerYAnchor.constraint(equalTo: plate.centerYAnchor),

            // The band between the field and the first project island. `space3`, not a breath: the
            // islands are beds, and a bed starting just under the search plate read as if the field
            // were part of the first group (user-reported 2026-08-09).
            scroll.topAnchor.constraint(equalTo: plate.bottomAnchor, constant: Slate.Metric.space3),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            foot.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            // The list's own gutter — the island lines up with the project beds above it.
            foot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            foot.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            foot.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Slate.Metric.space2),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        paint()
    }

    /// Every dynamic ink this controller stamps into a `CALayer` or an `NSImage`, re-resolved for the
    /// live appearance. A `CGColor` is FLAT — it does not follow a theme flip on its own.
    private func paint() {
        view.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        plate.layer?.backgroundColor = Slate.Native.State.hover.cgColor
        plate.layer?.borderColor = Slate.Native.Line.field.cgColor
        let icon = NSImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Slate.Native.Text.icon]))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(icon)
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")?
            .withSymbolConfiguration(icon)
    }

    // MARK: The live rebuild

    /// Re-derive the sections and reconcile the mounted islands against them, re-arming for the next
    /// STRUCTURAL change. Volatile chrome never reaches here: the rows and headers read their own.
    private func refresh() {
        var rows: [RailRow] = []
        var order: [TabID] = []
        withObservationTracking {
            rows = rowsMemo.rows(for: store)
            order = store.flatOrderedTabIDs()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        reconcile(rows: rows, tabOrder: order)
    }

    private func reconcile(rows: [RailRow], tabOrder: [TabID]) {
        let sections = SidebarSections.sections(rows, tabOrder: tabOrder, query: query)
        // The beds are dealt for the WHOLE column at once — see this file's header.
        let deal = Slate.ProjectTint.Deal(keys: sections.map { $0.header == nil ? nil : $0.projectKey })

        if let line = SidebarSections.emptyLine(rows: rows, sections: sections) {
            empty.stringValue = line
            empty.isHidden = false
        } else {
            empty.isHidden = true
        }

        var next: [String: MacSidebarIslandView] = [:]
        for (index, section) in sections.enumerated() {
            let key = SidebarSections.collapseKey(section.projectKey)
            let island = mounted[key] ?? MacSidebarIslandView(
                store: store, paneDrag: paneDrag, preventSleep: preventSleepAccess,
            )
            island.onToggle = { [weak self] in self?.toggle(key) }
            island.apply(
                section: section, bed: section.header == nil ? nil : deal.indices[index],
                collapsed: collapsed.contains(key),
            )
            next[key] = island
        }
        for (key, island) in mounted where next[key] == nil {
            islands.removeArrangedSubview(island)
            island.removeFromSuperview()
        }
        mounted = next
        // Re-order in place: an island that kept its identity keeps its plate, its hover and its
        // tracking areas, so a section moving up the column does not restart every row in it.
        for (index, section) in sections.enumerated() {
            guard let island = next[SidebarSections.collapseKey(section.projectKey)] else { continue }
            if islands.arrangedSubviews.firstIndex(of: island) != index {
                islands.insertArrangedSubview(island, at: index)
                island.widthAnchor.constraint(equalTo: islands.widthAnchor).isActive = true
            }
        }
        syncNewTabSlot()
    }

    /// The row menu's host-LOCAL sleep flag, as a live pair. `nil` (no preferences store — a preview or
    /// a pre-injection shell) hides the row rather than offering a dead control.
    private var preventSleepAccess: (get: () -> Bool, set: (Bool) -> Void)? {
        guard let preferences else { return nil }
        return (
            // `?? false` mirrors the daemon's default-OFF (`nil` ⇒ unset).
            get: { preferences.agent.preventSleep ?? false },
            set: { preferences.agent.preventSleep = $0 },
        )
    }

    private func toggle(_ key: String) {
        // Animated (otty snaps its collapse in one frame; the glide is a deliberate refinement) — the
        // chevron turns, the rows fold away and the islands below slide up in the same curve.
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.standard.duration
            context.timingFunction = Slate.Motion.standard.timingFunction
            context.allowsImplicitAnimation = true
            refresh()
            view.layoutSubtreeIfNeeded()
        }
    }

    /// The New-Tab drop slot — mounted (and its frame registered) only while a pane drag is in flight,
    /// pinned ABOVE the footer so it never needs scrolling into view.
    private func syncNewTabSlot() {
        guard let paneDrag else { return }
        var live = false
        withObservationTracking {
            live = paneDrag.drag != nil
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.syncNewTabSlot() }
            }
        }
        if live, newTabSlot == nil {
            let slot = MacNewTabDropSlot(coordinator: paneDrag)
            foot.insertArrangedSubview(slot, at: 0)
            slot.widthAnchor.constraint(equalTo: foot.widthAnchor).isActive = true
            newTabSlot = slot
        } else if !live, let slot = newTabSlot {
            foot.removeArrangedSubview(slot)
            slot.removeFromSuperview()
            newTabSlot = nil
        }
    }

    // MARK: The search field

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === search else { return }
        query = field.stringValue
        clear.isHidden = query.isEmpty
        refresh()
    }

    /// The field editor exists only once editing begins — the caret cannot be inked earlier.
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = Slate.Native.Text.primary
    }

    @objc
    private func clearQuery() {
        search.stringValue = ""
        query = ""
        clear.isHidden = true
        refresh()
    }
}

// MARK: - One project island

/// One project's ISLAND: the group's header and its rows on one bed washed in the project's identity
/// hue. A section with no header is the ungrouped flat list — it gets NO bed, because there is no
/// project for a colour to name.
///
/// The island is also the SELECTION PLATE's travel boundary (user-directed 2026-08-10): the plate
/// belongs to THIS island and to no other, so focus moving between two rows of this project slides it
/// across, while focus arriving from another project finds no plate here to move and it IGNITES in
/// place instead.
@MainActor
final class MacSidebarIslandView: NSView {
    private let store: WorkspaceStore
    private let paneDrag: PaneDragCoordinator?
    private let preventSleep: (get: () -> Bool, set: (Bool) -> Void)?

    private let stack = NSStackView()
    private var header: MacSidebarHeaderView?
    private var rows: [PaneID: MacSidebarRowView] = [:]
    private var order: [PaneID] = []

    /// The travelling plate. One layer, moved — never one background per row that cross-fades
    /// (user-directed 2026-08-09: selection "jumped").
    private let selection = CALayer()
    private var selected: PaneID?
    private var bed: Int?

    var onToggle: () -> Void = {}

    init(
        store: WorkspaceStore, paneDrag: PaneDragCoordinator?,
        preventSleep: (get: () -> Bool, set: (Bool) -> Void)?,
    ) {
        self.store = store
        self.paneDrag = paneDrag
        self.preventSleep = preventSleep
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.islandRadiusCompact
        layer?.cornerCurve = .continuous

        selection.cornerRadius = Slate.Metric.islandRadiusCompact
        selection.cornerCurve = .continuous
        selection.borderWidth = Slate.Metric.hairline
        selection.isHidden = true
        layer?.addSublayer(selection)

        stack.orientation = .vertical
        // `.width` — every row spans the island's row column, which is what the selection plate is
        // sized against below.
        stack.alignment = .width
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Slate.Metric.projectIslandInset,
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.projectIslandInset,
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Render one section. Rows that survive are UPDATED in place, so a section that gains a sibling
    /// does not restart the hover, the spinner or the drop registration of every row in it.
    func apply(section: SidebarSection, bed: Int?, collapsed: Bool) {
        self.bed = bed
        if let title = section.header {
            let view = header ?? {
                let created = MacSidebarHeaderView(
                    store: store, title: title, projectKey: section.projectKey,
                    rows: section.rows, collapsed: collapsed,
                )
                created.onToggle = { [weak self] in self?.onToggle() }
                stack.insertArrangedSubview(created, at: 0)
                created.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                header = created
                return created
            }()
            view.update(rows: section.rows)
            view.setCollapsed(collapsed, animated: true)
        }

        let wanted = collapsed ? [] : section.rows
        var next: [PaneID: MacSidebarRowView] = [:]
        for row in wanted {
            let view = rows[row.id] ?? MacSidebarRowView(
                row: row, store: store, paneDrag: paneDrag, preventSleep: preventSleep,
                fallbackTitle: PaneChooserRegistry.option(for: row.kind).title,
            )
            view.onSelect = { [weak self] in
                guard let self else { return }
                SidebarSelection.select(row.id, in: store)
            }
            next[row.id] = view
        }
        for (id, view) in rows where next[id] == nil {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = next
        order = wanted.map(\.id)
        let offset = header == nil ? 0 : 1
        for (index, id) in order.enumerated() {
            guard let view = next[id] else { continue }
            if stack.arrangedSubviews.firstIndex(of: view) != index + offset {
                stack.insertArrangedSubview(view, at: index + offset)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            view.refresh()
        }
        trackSelection()
        needsDisplay = true
        updateLayer()
    }

    /// Follow the focused pane and move — or ignite — the plate.
    private func trackSelection() {
        var focused: PaneID?
        withObservationTracking {
            focused = store.tree.activeSession?.activeTab?.activePane
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.trackSelection() }
            }
        }
        let next = focused.flatMap { rows[$0] == nil ? nil : $0 }
        guard next != selected else { return }
        let arriving = selected == nil
        selected = next
        moveSelection(igniting: arriving)
    }

    /// The plate's travel. Arriving from ANOTHER island there is no plate here to move, so it IGNITES:
    /// it appears at ``Slate/Anim/plateIgniteScale`` of its own height and settles, which reads as the
    /// selection landing rather than as a plate teleporting in.
    private func moveSelection(igniting: Bool) {
        guard let selected, let row = rows[selected] else {
            selection.isHidden = true
            return
        }
        layoutSubtreeIfNeeded()
        let frame = plateFrame(for: row)
        selection.isHidden = false
        if igniting {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selection.frame = frame
            CATransaction.commit()
            let grow = CABasicAnimation(keyPath: "transform.scale.y")
            grow.fromValue = Slate.Anim.plateIgniteScale
            grow.toValue = 1
            grow.duration = Slate.Motion.selectionMorph.duration
            grow.timingFunction = Slate.Motion.selectionMorph.timingFunction
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Slate.Motion.selectionMorph.duration
            fade.timingFunction = Slate.Motion.selectionMorph.timingFunction
            selection.add(grow, forKey: "ignite")
            selection.add(fade, forKey: "igniteFade")
            return
        }
        let travel = CABasicAnimation(keyPath: "frame")
        travel.duration = Slate.Motion.selectionMorph.duration
        travel.timingFunction = Slate.Motion.selectionMorph.timingFunction
        selection.frame = frame
        selection.add(travel, forKey: "travel")
    }

    override var wantsUpdateLayer: Bool { true }

    /// The bed and the plate, re-resolved: a `CGColor` is flat and does not follow a theme flip.
    ///
    /// The plate's fill is the ISLAND's own material and its edge is the GLASS's rim — a chip stamped
    /// out of the island's material has to carry the island's rim too, or the two surfaces stop being
    /// the same object the moment the ground stops being the thing that separates them. NO drop shadow
    /// (user-directed 2026-08-09): the chip is ~13:1 from the ground already, and a cast edge dragged
    /// behind the travelling plate is the one thing a flat vocabulary cannot afford.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = bed == nil
                ? NSColor.clear.cgColor
                : Slate.Native.ProjectTint.bed(at: bed).cgColor
            selection.backgroundColor = Slate.Native.Surface.island.cgColor
            selection.borderColor = Slate.Native.Terminal.edge.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let selected, let row = rows[selected], !selection.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.frame = plateFrame(for: row)
        CATransaction.commit()
    }

    /// Where the plate stands: the ROW's band vertically, the row COLUMN's full span horizontally.
    ///
    /// ⚠️ `stack.layoutSubtreeIfNeeded()` first, and the width comes from the STACK. A row is a
    /// grandchild — the stack positions it, not this view — so at `layout()` time the row's frame is
    /// whatever the PREVIOUS pass left, and reading it straight gave the plate the row's INTRINSIC
    /// width: a chip hugging the title with the active row's white-on-glass ink running off it onto
    /// the cream. Caught by `MacChromeSnapshotRender.testRenderNavigatorGrouped`.
    private func plateFrame(for row: MacSidebarRowView) -> CGRect {
        stack.layoutSubtreeIfNeeded()
        let band = convert(row.bounds, from: row)
        return CGRect(x: stack.frame.minX, y: band.minY, width: stack.frame.width, height: band.height)
    }
}

// MARK: - The New-Tab drop slot

/// Dropping here breaks the dragged pane into its own fresh tab. Mounted only while a drag is live, so
/// its registered frame exists for exactly the drag's duration.
@MainActor
final class MacNewTabDropSlot: NSView {
    private let coordinator: PaneDragCoordinator
    private let label = NSTextField(labelWithString: "New Tab")
    private let glyph = NSImageView()
    private var active = false

    init(coordinator: PaneDragCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        let stack = NSStackView(views: [glyph, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(
                equalToConstant: Slate.Metric.heightTabRow + CGFloat(Slate.Metric.space2),
            ),
        ])
        coordinator.register(.newTabZone) { [weak self] in
            guard let self, let window else { return nil }
            return window.convertToScreen(convert(bounds, to: nil))
        }
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    deinit {
        MainActor.assumeIsolated { coordinator.unregister(.newTabZone) }
    }

    private func follow() {
        var next = false
        withObservationTracking {
            next = coordinator.drag?.destination == .newTab
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        guard next != active else { return }
        active = next
        needsDisplay = true
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink = active ? Slate.Native.Text.primary : Slate.Native.Text.secondary
            // A row-shaped affordance inside the list, so it reads on the ROWS' rung.
            label.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
            label.textColor = ink
            glyph.image = NSImage(
                systemSymbolName: "plus.square.on.square", accessibilityDescription: nil,
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
            layer?.backgroundColor = active
                ? Slate.Native.State.accentMuted.cgColor
                : NSColor.clear.cgColor
        }
    }

    /// The dashed rim — a `CALayer` border cannot dash, so the slot's own edge is stroked.
    override func draw(_: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Slate.Metric.radiusSmall, yRadius: Slate.Metric.radiusSmall,
        )
        path.lineWidth = active ? 2 : 1
        path.setLineDash([5, 4], count: 2, phase: 0)
        (active ? Slate.Native.accent : Slate.Native.Line.subtle).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
