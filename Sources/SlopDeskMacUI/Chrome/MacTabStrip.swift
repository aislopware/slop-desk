// MacTabStrip — the tabs, laid HORIZONTALLY in the titlebar band, for the state where the sidebar is
// hidden. In AppKit, with the navigator column it mirrors (docs/56 stage D).
//
// Collapsing the navigator used to cost the whole tab list: the panes were still there and still
// switchable by chord, but nothing on screen said which ones existed or which one was live. The strip
// is that list rotated 90° into the band the island's top moat already reserves — so hiding the
// sidebar buys back its width without giving up the one thing it was for.
//
// It is the SAME MODEL as the sidebar, deliberately: the same memoized rows, the same By-Project
// sectioning (``SidebarSections``), the same beds dealt for the whole RUN, the same per-island
// travelling selection plate, and the same per-row reading (``SidebarRowReading``) — of which a chip
// draws a strict SUBSET. That is why there is no `TabChipReading`: a chip is a navigator row with the
// second register dropped, and giving it its own resolver would be two answers to "what is this pane
// called" one refactor away from disagreeing.
//
// What the horizontal form gives up is that second register: no git line, no cwd subtitle, no process
// label, no receipt. A chip is a title, its status mark and its bed. The chips share one band row with
// the window controls — there is room for identity, not for readouts, and the readouts are one ⌘⇧L
// away.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

@MainActor
final class MacTabStrip: NSView {
    private let store: WorkspaceStore

    /// The memoized row model — the strip's OWN memo, not the navigator's: only one of the two is ever
    /// mounted, and a memo threaded down from the window root would put the structural build in the
    /// root's refresh, the one place ``RailRowsMemo`` exists to keep it out of.
    private let rowsMemo = RailRowsMemo()

    private let scroll = NSScrollView()
    private let islands = NSStackView()
    private var mounted: [String: MacTabIslandView] = [:]

    init(store: WorkspaceStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        islands.orientation = .horizontal
        islands.alignment = .centerY
        // `space2` between beds, not a hairline: the beds ARE the grouping, and what separates two
        // projects here is the gap between their runs.
        islands.spacing = Slate.Metric.space2
        islands.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(islands)

        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            islands.topAnchor.constraint(equalTo: document.topAnchor),
            islands.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            islands.leadingAnchor.constraint(
                equalTo: document.leadingAnchor, constant: Slate.Metric.space1,
            ),
            islands.trailingAnchor.constraint(
                equalTo: document.trailingAnchor, constant: -Slate.Metric.space1,
            ),
            // Exactly one control tall — the bed IS its run of tabs, with no collar in either axis. A
            // collar made this the tallest row in the band, where every other tab across the window is
            // a plain control rung, and left a stub of tint hanging off each end of a run.
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])
    }

    // MARK: The live rebuild

    /// Re-derive the sections and reconcile the mounted islands against them, following the next
    /// STRUCTURAL change. Volatile chrome never reaches here: the chips read their own.
    private func refresh() {
        ObservationFollow.arm(self) { strip in
            (rows: strip.rowsMemo.rows(for: strip.store), order: strip.store.flatOrderedTabIDs())
        } apply: { strip, reading in
            strip.reconcile(rows: reading.rows, tabOrder: reading.order)
        }
    }

    private func reconcile(rows: [RailRow], tabOrder: [TabID]) {
        let sections = SidebarSections.sections(rows, tabOrder: tabOrder, query: "")
        // The beds are dealt for the RUN, not per section: two projects whose basenames hash alike
        // must not stand shoulder to shoulder in one colour, and only the ordered list knows that. The
        // strip's order is the sidebar's order rotated, so both surfaces deal identically.
        //
        // A KEYLESS section still gets a bed (the neutral one) — unlike the navigator, where a
        // headerless flat list draws none: the strip's rhythm is the beds, and a video pane sitting
        // between two projects with no ground under it reads as a gap in the run.
        let deal = Slate.ProjectTint.Deal(keys: sections.map(\.projectKey))

        var next: [String: MacTabIslandView] = [:]
        for (index, section) in sections.enumerated() {
            let key = SidebarSections.collapseKey(section.projectKey)
            let island = mounted[key] ?? MacTabIslandView(store: store)
            island.apply(section: section, bed: deal.indices[index])
            next[key] = island
        }
        for (key, island) in mounted where next[key] == nil {
            islands.removeArrangedSubview(island)
            island.removeFromSuperview()
        }
        mounted = next
        // Re-order in place: an island that kept its identity keeps its plate, its hover and its
        // tracking areas, so a section moving along the band does not restart every chip in it.
        for (index, section) in sections.enumerated() {
            guard let island = next[SidebarSections.collapseKey(section.projectKey)] else { continue }
            if islands.arrangedSubviews.firstIndex(of: island) != index {
                islands.insertArrangedSubview(island, at: index)
            }
        }
    }
}

// MARK: - One project's run

/// One project's run of tabs on its own bed, and the SELECTION PLATE's travel boundary — the same
/// seam the navigator's islands draw: the plate slides between two tabs of one project and IGNITES in
/// place when it arrives from another. The two surfaces must agree, because they render the same rows
/// in the same order and only one is ever mounted; a rule that held on one axis and not the other
/// would read as the gesture changing when the sidebar is hidden.
@MainActor
private final class MacTabIslandView: NSView {
    private let store: WorkspaceStore
    private let stack = NSStackView()
    private var chips: [PaneID: MacTabChipView] = [:]
    private var order: [PaneID] = []

    private let selection = CALayer()
    private var selected: PaneID?
    private var bed: Int?
    /// See ``trackSelection()``: this island is REUSED across reconciles, so each arm must displace
    /// the last.
    private var selectionFollow: ObservationFollow?

    init(store: WorkspaceStore) {
        self.store = store
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

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // NO collar in either axis — the bed ends where its tabs do.
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func apply(section: SidebarSection, bed: Int?) {
        self.bed = bed
        var next: [PaneID: MacTabChipView] = [:]
        for row in section.rows {
            let chip = chips[row.id] ?? MacTabChipView(
                row: row, store: store,
                fallbackTitle: PaneChooserRegistry.option(for: row.kind).title,
            )
            next[row.id] = chip
        }
        for (id, chip) in chips where next[id] == nil {
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        chips = next
        order = section.rows.map(\.id)
        for (index, id) in order.enumerated() {
            guard let chip = next[id] else { continue }
            if stack.arrangedSubviews.firstIndex(of: chip) != index {
                stack.insertArrangedSubview(chip, at: index)
            }
            chip.refresh()
        }
        trackSelection()
        needsDisplay = true
        updateLayer()
    }

    /// Follow the focused pane and move — or ignite — the plate.
    ///
    /// `replacing:` although this method has ONE caller: that caller is ``apply(section:bed:)``, which
    /// the strip re-runs against this REUSED island on every reconcile. A plain arm would leave one
    /// live chain per reconcile, all of them moving the same plate.
    private func trackSelection() {
        selectionFollow = ObservationFollow.arm(self, replacing: selectionFollow) { island in
            island.store.tree.activeSession?.activeTab?.activePane
        } apply: { island, focused in
            let next = focused.flatMap { island.chips[$0] == nil ? nil : $0 }
            guard next != island.selected else { return }
            let arriving = island.selected == nil
            island.selected = next
            island.moveSelection(igniting: arriving)
        }
    }

    /// The plate's travel. Arriving from ANOTHER island there is no plate here to move, so it IGNITES:
    /// it appears at ``Slate/Anim/plateIgniteScale`` of its own height and settles, which reads as the
    /// selection landing rather than as a plate teleporting in.
    private func moveSelection(igniting: Bool) {
        guard let selected, let chip = chips[selected] else {
            selection.isHidden = true
            return
        }
        layoutSubtreeIfNeeded()
        let frame = plateFrame(for: chip)
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

    override func layout() {
        super.layout()
        guard let selected, let chip = chips[selected], !selection.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.frame = plateFrame(for: chip)
        CATransaction.commit()
    }

    /// Where the plate stands: the CHIP's own footprint. ⚠️ `stack.layoutSubtreeIfNeeded()` first — a
    /// chip is this view's GRANDCHILD, so at `layout()` time its frame is whatever the previous pass
    /// left (the navigator hit exactly this, and got a plate one word wide).
    private func plateFrame(for chip: MacTabChipView) -> CGRect {
        stack.layoutSubtreeIfNeeded()
        return convert(chip.bounds, from: chip)
    }

    override var wantsUpdateLayer: Bool { true }

    /// The bed and the plate, re-resolved: a `CGColor` is flat and does not follow a theme flip. The
    /// plate's fill is the ISLAND's own material and its edge is the GLASS's rim — a chip stamped out
    /// of the island's material has to carry the island's rim too.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.ProjectTint.bed(at: bed).cgColor
            selection.backgroundColor = Slate.Native.Surface.island.cgColor
            selection.borderColor = Slate.Native.Terminal.edge.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - One chip

/// One LIVE chip. Same contract as a navigator row: the STRUCTURAL identity rides the memoized
/// ``RailRow`` while selection, the fused badge and the shown title are re-read HERE — so a status
/// tick or a focus change repaints this leaf and never the strip above it.
@MainActor
private final class MacTabChipView: NSView {
    private let row: RailRow
    private let store: WorkspaceStore
    private let fallbackTitle: String

    private let title = NSTextField(labelWithString: "")
    private let mark = MacStatusMarkView()

    private var reading: SidebarRowReading
    /// See ``refresh()``: the island re-runs it on this REUSED chip every reconcile, so each arm must
    /// displace the last.
    private var chipFollow: ObservationFollow?
    private var hovering = false
    private var tracking: NSTrackingArea?

    /// A chip never grows past this, however long a running command's title runs — one wide tab must
    /// not push every other tab out of the band.
    private static let maxWidth: CGFloat = 160

    init(row: RailRow, store: WorkspaceStore, fallbackTitle: String) {
        self.row = row
        self.store = store
        self.fallbackTitle = fallbackTitle
        reading = SidebarRowPresentation.reading(
            for: row, store: store, fallbackTitle: fallbackTitle,
        )
        super.init(frame: .zero)
        build()
        apply(reading)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.islandRadiusCompact
        layer?.cornerCurve = .continuous

        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(mark)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.leadingAnchor.constraint(
                equalTo: title.trailingAnchor, constant: Slate.Metric.space1,
            ),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
        ])
    }

    /// Re-resolve this chip against the store and repaint.
    ///
    /// `replacing:` although nothing in this file calls it twice: the island calls `refresh()` on this
    /// REUSED chip on every reconcile, so a plain arm would leave one live chain per reconcile.
    func refresh() {
        chipFollow = ObservationFollow.arm(self, replacing: chipFollow) { chip in
            SidebarRowPresentation.reading(
                for: chip.row, store: chip.store, fallbackTitle: chip.fallbackTitle,
            )
        } apply: { chip, next in
            guard next != chip.reading else { return }
            chip.reading = next
            chip.apply(next)
        }
    }

    private func apply(_ reading: SidebarRowReading) {
        // The chip is stamped out of the terminal island's material, so what stands ON it reads
        // against the ISLAND's polarity — the same one line the navigator's selected row spends.
        appearance = reading.active
            ? NSAppearance(named: Slate.glassColorScheme == .dark ? .darkAqua : .aqua)
            : nil
        toolTip = reading.title
        setAccessibilityLabel(reading.title)

        // The otty agent-integration look: only an AGENT session's title wears the leading `✳`.
        title.attributedStringValue = .slateNerdAware(
            reading.agentMarker ? RailRowsBuilder.agentMarkedTitle(reading.title) : reading.title,
            font: .systemFont(ofSize: Slate.Typeface.footnote, weight: weight(reading.titleWeight)),
            // ⚠️ The navigator's URGENT-title hue deliberately stops at the navigator: this strip
            // names the SPLITS of the tab you are already in, and its chips are one line apart from
            // the mark that carries the hue. The WEIGHT step is shared — a state that WAITS on you
            // reads bolder than the active chip's own `.medium`.
            color: reading.active ? Slate.Native.Text.primary : Slate.Native.Text.secondary,
        )
        mark.style = StatusPresentation.statusDot(
            working: reading.workingLabel != nil, badge: reading.badge,
            agentIdle: reading.agentIdle, agentFinish: reading.agentFinish,
        )
        needsDisplay = true
        updateLayer()
    }

    private func weight(_ rung: RowTitleWeight) -> NSFont.Weight {
        switch rung {
        case .resting: .regular
        case .active: .medium
        case .attention: .semibold
        }
    }

    override var wantsUpdateLayer: Bool { true }

    /// The SELECTED plate is NOT here — it belongs to the island, because it TRAVELS. All this leaf
    /// paints is the unselected chip's hover tint.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering && !reading.active
                ? Slate.Native.State.hover.cgColor
                : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Hover + the click

    private func track() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        track()
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            updateLayer()
        }
    }

    /// ONE select path with the sidebar's rows: switch to the owning tab, focus the pane, clear the
    /// tab's agent badges.
    override func mouseDown(with _: NSEvent) {
        SidebarSelection.select(row.id, in: store)
    }
}
