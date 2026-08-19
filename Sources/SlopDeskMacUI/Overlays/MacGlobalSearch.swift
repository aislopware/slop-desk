// MacGlobalSearch — the ⇧⌘F cross-tab results panel, in AppKit.
//
// The sixth surface off the shared SwiftUI floor (docs/56 stage D), and the last modal one before
// Open Quickly. It is the palette's shape with one thing taken away and one added: there is no
// keyboard cursor down the list — the POINTER is the selection here, which is why hover lifts a row
// onto the same plate a palette's keyboard selection takes — and the list is two levels deep, a
// collapsible group per tab over its own hit rows.
//
// The panel rides ``MacOverlayPanelController``, so the dismiss floor, Esc and the first-responder
// handback are the panel's. It is FIXED-SIZE, unlike the palette and the peek card: a results surface
// that grew and shrank with the match count would move under the pointer on every keystroke, and the
// query re-runs on every keystroke here.
//
// What it does not own: ``GlobalSearchController`` runs every match (never a second matcher),
// ``WorkspaceStore/runGlobalSearch`` owns the query and the flags, ``GlobalSearchCollapseState`` is
// the disclosure reducer, and ``GlobalSearchPresentation`` cuts the excerpt around its highlight,
// words the two zero states and gates the summary line. The mode pills are ``FindModePill`` — the
// same values the in-pane find bar reads, which is how the locked "the find bar and the
// global-search query bar render the pills IDENTICALLY" invariant survives one of them becoming an
// `NSView`.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The panel's content

@MainActor
final class MacGlobalSearchView: NSView, NSTextFieldDelegate {
    private let store: WorkspaceStore
    private let coordinator: OverlayCoordinator

    private let field = NSTextField()
    private let pills: [FindModePill: MacFindTogglePillView]
    private let rule = MacCardRuleView()
    private let summary = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let column = NSStackView()

    /// The live query and flags. Mirrors of the store's retained ones, restored on the way in so a
    /// re-open shows the last search rather than a blank field over stale results.
    private var query = ""
    private var caseSensitive = false
    private var isRegex = false
    /// Which tab groups are folded shut. Keyed by ``PaneID``, so a live re-run that re-orders or
    /// drops groups carries the intent to the panes that survived and lets a vanished one fall away.
    private var collapse = GlobalSearchCollapseState()

    /// The rows currently in the column, in draw order. Rebuilt whenever the SHAPE of the list
    /// changes; re-cut in place when only its content did.
    private var rows: [MacGlobalSearchRowView] = []

    init(store: WorkspaceStore, coordinator: OverlayCoordinator) {
        self.store = store
        self.coordinator = coordinator
        pills = Dictionary(
            uniqueKeysWithValues: FindModePill.globalSearch.map { ($0, MacFindTogglePillView($0)) },
        )
        super.init(frame: .zero)

        let bar = buildQueryBar()
        buildSummary()
        buildResults()
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Slate.Metric.heightInput),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            summary.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: Slate.Metric.space2),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: Slate.Metric.space2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func buildQueryBar() -> NSView {
        // No leading magnifier and no in-bar `×`: the query is flush-left and Esc is the way out.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Overlay.primary
        field.placeholderString = "Search across all tabs…"
        field.delegate = self

        // The field SINKS into a well while the pills sit on plates that RISE — opposite directions
        // from the same card, which is what tells an editable region from a pressable one without
        // either needing a label.
        let well = MacGlobalSearchWellView()
        well.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Slate.Metric.space2),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = Slate.Metric.space2
        bar.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space4, bottom: 0, right: Slate.Metric.space4,
        )
        bar.addView(well, in: .leading)
        // A TRANSPARENT tray: the chips delineate themselves, so the container only spaces them.
        let tray = NSStackView()
        tray.orientation = .horizontal
        tray.spacing = Slate.Metric.space1
        for mode in FindModePill.globalSearch {
            guard let pill = pills[mode] else { continue }
            pill.onToggle = { [weak self] in self?.toggle(mode) }
            tray.addArrangedSubview(pill)
        }
        bar.addView(tray, in: .trailing)
        well.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        return bar
    }

    private func buildSummary() {
        summary.font = .monospacedDigitSystemFont(
            ofSize: Slate.Typeface.footnote, weight: .regular,
        )
        summary.textColor = Slate.Native.Overlay.secondary
        summary.isSelectable = false
        summary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summary)
    }

    private func buildResults() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space3,
            bottom: Slate.Metric.space1, right: Slate.Metric.space3,
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = column
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    // MARK: Presentation

    /// Restores the last search, gives the field the keyboard and draws. Called once the panel is on
    /// screen — a field cannot become first responder in a window that is not yet key.
    ///
    /// It does NOT re-run the search: the store still holds the last result set, and re-running would
    /// spend a full cross-tab scan to arrive at what is already on screen.
    func begin() {
        query = store.globalSearchQuery
        caseSensitive = store.globalSearchCaseSensitive
        isRegex = store.globalSearchRegex
        field.stringValue = query
        for (mode, pill) in pills { pill.setOn(isOn(mode)) }
        window?.makeFirstResponder(field)
        render()
    }

    private func render() {
        withObservationTracking {
            draw()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.render() }
            }
        }
    }

    private func draw() {
        // Emptied rather than HIDDEN: a hidden label keeps its frame anyway, and on a fixed-size panel
        // that is the behaviour to want — the results below do not jump a line up and down as the
        // first keystroke of a search brings the count into being.
        summary.stringValue = GlobalSearchPresentation.summary(store.globalSearch, query: query) ?? ""
        drawRows(store.globalSearch?.groups ?? [])
    }

    /// The list, flattened: a header line per group and a hit line per visible hit.
    ///
    /// Flat because that is what it IS — the groups are headings over one continuous run of rows, not
    /// nested containers — and because a folded group then costs exactly the rows it hides.
    private func drawRows(_ groups: [GlobalSearchGroup]) {
        var lines: [MacGlobalSearchRowView.Line] = []
        for group in groups {
            lines.append(.group(group, collapsed: collapse.isCollapsed(group.paneID)))
            guard collapse.showsHits(group.paneID) else { continue }
            lines.append(contentsOf: group.hits.map { .hit($0) })
        }
        if lines.isEmpty {
            lines = [.empty(GlobalSearchPresentation.emptyStateLine(query: query))]
        }
        if rows.count != lines.count {
            for row in rows {
                column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = lines.map { _ in
                let row = MacGlobalSearchRowView()
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: column.widthAnchor, constant: -Slate.Metric.space3 * 2,
                ).isActive = true
                return row
            }
        }
        for (row, line) in zip(rows, lines) {
            row.show(line, onActivate: { [weak self] in self?.activate(line) })
        }
    }

    // MARK: The keyboard and the pointer

    func controlTextDidChange(_: Notification) {
        query = field.stringValue
        rerun()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        coordinator.closeGlobalSearch()
        return true
    }

    private func toggle(_ mode: FindModePill) {
        switch mode {
        case .caseSensitive: caseSensitive.toggle()
        case .regex: isRegex.toggle()
        // Not offered here — the cross-tab search runs over a scrollback mirror rather than over
        // libghostty's own buffer, and the two do not agree about a word boundary.
        case .wholeWord: return
        }
        pills[mode]?.setOn(isOn(mode))
        rerun()
    }

    private func isOn(_ mode: FindModePill) -> Bool {
        switch mode {
        case .caseSensitive: caseSensitive
        case .regex: isRegex
        case .wholeWord: false
        }
    }

    private func rerun() {
        store.runGlobalSearch(query: query, caseSensitive: caseSensitive, isRegex: isRegex)
        // Straight to `draw()`, not left to the observation edge: the summary line and the zero state
        // are worded from the QUERY as well as from the results, and a keystroke that leaves the
        // result set identical — clearing the last character of a search that already matched nothing
        // — moves nothing the tracker is watching.
        draw()
    }

    /// A group header folds; a hit row JUMPS and closes the panel behind it.
    private func activate(_ line: MacGlobalSearchRowView.Line) {
        switch line {
        case let .group(group, _):
            collapse.toggle(group.paneID)
            draw()
        case let .hit(hit):
            store.jumpToGlobalSearchResult(hit)
            coordinator.closeGlobalSearch()
        case .empty:
            break
        }
    }
}

// MARK: - The query's well

/// The plate the query field sinks into — the same recipe every editable field on a summoned card
/// takes, so an input looks the same wherever it lands.
final class MacGlobalSearchWellView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        heightAnchor.constraint(equalToConstant: Slate.Metric.plate).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.well.cgColor
            layer?.borderColor = Slate.Native.Overlay.hairline.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - One mode pill

/// A compact `Aa` / `.*` toggle chip.
///
/// ⚠️ LOCKED RENDERING, and the lock is the reason this file may hold a second one at all: every idle
/// chip is INDIVIDUALLY DELINEATED — its own plate and hairline, never a bare glyph — and the find
/// bar's chips and these must read identically. What keeps them identical is ``FindModePill`` (the
/// label and the help) plus ``FindTogglePillAppearance`` (which of the three states is showing); what
/// is here is only the rung → `NSColor` lookup.
@MainActor
final class MacFindTogglePillView: NSView {
    var onToggle: () -> Void = {}

    private let glyph = NSTextField(labelWithString: "")
    private var isOn = false
    private var hovering = false

    override var wantsUpdateLayer: Bool { true }

    init(_ mode: FindModePill) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline

        glyph.attributedStringValue = Self.label(mode)
        glyph.alignment = .center
        glyph.isSelectable = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        toolTip = mode.help
        setAccessibilityLabel(mode.help)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.plate),
            heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Slate.Metric.space1,
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private static func label(_ mode: FindModePill) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: Slate.Typeface.footnote, weight: .semibold,
            ),
        ]
        if mode.underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: mode.label, attributes: attributes)
    }

    func setOn(_ on: Bool) {
        isOn = on
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // One arm per STATE rather than three ternaries per property: the recipe is "what does an
            // idle / hovered / on chip look like", and split across three conditionals a state can be
            // half-changed. The verdict itself is ``FindTogglePillAppearance``, shared with the in-pane
            // find bar's chips — what is left here is the rung → `NSColor` lookup, this renderer's alone.
            switch FindTogglePillAppearance.resolve(isOn: isOn, hovering: hovering) {
            case .idle:
                layer?.backgroundColor = Slate.Native.Surface.face.cgColor
                layer?.borderColor = Slate.Native.Line.subtle.cgColor
                glyph.textColor = Slate.Native.Text.secondary
            case .hovering:
                layer?.backgroundColor = Slate.Native.State.hover.cgColor
                layer?.borderColor = Slate.Native.Line.subtle.cgColor
                glyph.textColor = Slate.Native.Text.secondary
            case .on:
                layer?.backgroundColor = Slate.Native.State.accentMuted.cgColor
                layer?.borderColor = Slate.Native.accent.withAlphaComponent(0.5).cgColor
                glyph.textColor = Slate.Native.accent
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) {
        onToggle()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - One line of the list

/// A group header, a hit, or the zero state — three shapes down one column, so the row that draws
/// them is one view rather than three that would each be rebuilt whenever the list changed kind.
@MainActor
final class MacGlobalSearchRowView: NSView {
    enum Line {
        case group(GlobalSearchGroup, collapsed: Bool)
        case hit(GlobalSearchHit)
        case empty(String)
    }

    private let disclosure = NSImageView()
    private let terminal = NSImageView()
    private let text = NSTextField(labelWithString: "")
    private let arrow = NSImageView()

    private let content = NSStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var onActivate: () -> Void = {}
    /// Only a HIT lifts under the pointer, and only a hit shows the jump arrow — a header is a
    /// disclosure control and the zero state is a sentence.
    private var lifts = false
    private var hovering = false

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth

        for image in [disclosure, terminal, arrow] {
            image.imageScaling = .scaleNone
            image.contentTintColor = Slate.Native.Overlay.secondary
        }
        arrow.contentTintColor = Slate.Native.Overlay.tertiary
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .regular,
        )
        // `apple.terminal` is the `>_` PROMPT-BOX glyph, not an Apple-logo mark, and it is the
        // non-deprecated spelling of the symbol the bare `terminal` name used to carry.
        terminal.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
        terminal.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .regular,
        )
        disclosure.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.small, weight: .semibold,
        )

        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.isSelectable = false

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space2
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space3, bottom: 0, right: Slate.Metric.space3,
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [disclosure, terminal, text] as [NSView] { content.addView(view, in: .leading) }
        content.addView(arrow, in: .trailing)
        addSubview(content)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let height = heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: Slate.Typeface.body),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ line: Line, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        switch line {
        case let .group(group, collapsed): showGroup(group, collapsed: collapsed)
        case let .hit(hit): showHit(hit)
        case let .empty(message): showEmpty(message)
        }
        needsDisplay = true
    }

    private func showGroup(_ group: GlobalSearchGroup, collapsed: Bool) {
        lifts = false
        arrow.isHidden = true
        disclosure.isHidden = false
        terminal.isHidden = false
        // A header sits SHALLOWER than the hits under it, and taller: the indent is what makes the
        // group a group, and the extra air is the space between one tab's results and the next's.
        indent(Slate.Metric.space1)
        heightConstraint?.constant = Slate.Metric.heightRowTall
        disclosure.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: collapsed ? "Collapsed" : "Expanded",
        )
        text.attributedStringValue = NSAttributedString(
            string: group.groupTitle,
            attributes: [
                .font: Slate.Typeface.instrumentNative(Slate.Typeface.footnote, weight: .medium),
                .foregroundColor: Slate.Native.Overlay.secondary,
            ],
        )
        setAccessibilityLabel(group.groupTitle)
    }

    private func showHit(_ hit: GlobalSearchHit) {
        lifts = true
        disclosure.isHidden = true
        terminal.isHidden = true
        arrow.isHidden = !hovering
        indent(Slate.Metric.space3)
        heightConstraint?.constant = Slate.Metric.heightRow
        text.attributedStringValue = Self.marked(GlobalSearchPresentation.excerptSlices(hit))
        setAccessibilityLabel(hit.excerpt)
    }

    private func showEmpty(_ message: String) {
        lifts = false
        for view in [disclosure, terminal, arrow] { view.isHidden = true }
        indent(Slate.Metric.space1)
        heightConstraint?.constant = Slate.Metric.heightRowTall
        text.attributedStringValue = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: Slate.Typeface.body),
                .foregroundColor: Slate.Native.Overlay.tertiary,
            ],
        )
        setAccessibilityLabel(message)
    }

    /// How far in from the row's own edge the line starts. The row is the full width either way — it
    /// is the hover plate — so the indent moves the CONTENT, not the plate under it.
    private func indent(_ leading: Double) {
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: leading, bottom: 0, right: Slate.Metric.space3,
        )
    }

    /// The excerpt with its matched run lit: the line in the supporting ink, the hit in the reading
    /// ink over the warn wash — the SAME mark the in-pane find draws, because a result found here and
    /// the same result found in the pane must not be two different colours of found.
    private static func marked(_ excerpt: GlobalSearchExcerpt) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
        let spliced = NSMutableAttributedString(
            string: excerpt.before,
            attributes: [.font: font, .foregroundColor: Slate.Native.Overlay.secondary],
        )
        spliced.append(NSAttributedString(
            string: excerpt.match,
            attributes: [
                .font: font,
                .foregroundColor: Slate.Native.Overlay.primary,
                .backgroundColor: Slate.Native.Status.warn.withAlphaComponent(0.35),
            ],
        ))
        spliced.append(NSAttributedString(
            string: excerpt.after,
            attributes: [.font: font, .foregroundColor: Slate.Native.Overlay.secondary],
        ))
        return spliced
    }

    override func updateLayer() {
        let lit = lifts && hovering
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = lit
                ? Slate.Native.Overlay.plate.cgColor : NSColor.clear.cgColor
            layer?.borderColor = lit
                ? Slate.Native.Overlay.hairline.cgColor : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        arrow.isHidden = !lifts
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        arrow.isHidden = true
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) {
        onActivate()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
