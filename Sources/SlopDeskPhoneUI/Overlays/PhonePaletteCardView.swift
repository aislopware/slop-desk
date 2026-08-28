// PhonePaletteCardView — the phone's command palette, in UIKit (docs/62 stage F).
//
// The UIKit half of the deleted `PaletteView`: a pre-focused query field over a sectioned,
// fzf-highlighted result list with keycap chips, a ✓ toggled-state gutter and a keyboard-selected plate.
// It is a VERBS-ONLY palette — the per-domain filter chips live in the Open-Quickly picker, and ⌘⇧P shows
// none here.
//
// THE MAC DRAWS ITS OWN (``SlopDeskMacUI/MacPaletteView``, an `NSPanel` over the workspace). What the two
// halves share is ``PalettePresentation`` and ``PaletteMetrics`` — the card's measurements, the ranked
// rows paired with the keyboard's index, the ✓ predicate and the WORKING DIRECTORY badge — so neither
// re-derives a decision and each keeps only its arrangement.
//
// SEAM discipline: the palette OWNS no state. Every read and every mutation goes through the coordinator
// (the single `@Observable` reducer), so the GUI and the headless model cannot drift.
//
// ⚠️ A TABLE VIEW, NOT A STACK. This is the one overlay whose row count is UNBOUNDED — the zero state
// alone lists the whole verb catalog plus every open pane — so it is the diffable-data-source case
// docs/62 §3.4 draws the line at, and rebuilding ~100 row views on every keystroke is exactly what that
// line exists to prevent. The switcher and the cheat sheet stay stacks because their counts are bounded.
//
// ⚠️ NO HOVER GATE, and its absence is the platform rather than a dropped feature. The SwiftUI half
// carried a `HoverSelectionGate` to arbitrate between a pointer selecting a row and a keyboard scrolling
// one under a parked pointer; a touch device produces neither event, so every selection change here is
// keyboard-driven and the auto-scroll is unconditional.
//
// ⚠️ THE CHORDS HANG ON THE CARD, not on the field. `keyCommands` are dispatched from the FIRST RESPONDER
// upwards, and the responder while this card is up is the query field inside it — so the arrows and ⌘↩
// have to be declared on an ANCESTOR of that field to be reached at all. They also have to
// `wantsPriorityOverSystemBehavior`, or a bare ↑/↓ moves the text caret instead of the selection.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhonePaletteCardView: UIView {
    private let store: WorkspaceStore
    private let overlay: OverlayCoordinator
    private let toggledState: @MainActor (PaletteItem) -> Bool

    private let search = SlateSearchBarView(prompt: PalettePresentation.queryPrompt)
    private let table = UITableView(frame: .zero, style: .plain)
    private lazy var dataSource = makeDataSource()
    /// The viewport's height. `lazy` rather than an implicitly-unwrapped optional — it is minted from
    /// a stored view, so it cannot be built at the declaration, but it is never absent either.
    private lazy var tableHeight = table.heightAnchor.constraint(equalToConstant: .zero)

    /// The rows in draw order, and the same rows by id — the table hands back an ID and the cell needs
    /// the row.
    private var rows: [PaletteDisplayRow] = []
    private var byID: [String: PaletteDisplayRow] = [:]
    private var selection = 0
    /// The WORKING DIRECTORY header's contextual pill, or `nil` when the host has not answered for the
    /// focused pane's cwd yet — no pill rather than an empty one.
    private var badge: String?
    private var generation = 0

    init(
        store: WorkspaceStore,
        overlay: OverlayCoordinator,
        toggledState: @escaping @MainActor (PaletteItem) -> Bool,
    ) {
        self.store = store
        self.overlay = overlay
        self.toggledState = toggledState
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        SlatePaperCardSurface.layoutShadow(of: self)
    }

    // MARK: - Building

    private func build() {
        SlatePaperCardSurface.apply(to: self)
        // The card is a container for a focused field: everything below it must be reachable, and the
        // paper itself must not be an accessibility element in front of its own content.
        accessibilityViewIsModal = true

        search.onTextChange = { [overlay] text in overlay.paletteQuery = text }
        // Plain ↩ is the FIELD's submit rather than a key command: a text field owns Return, and taking
        // it away at the card would fight the keyboard's own return key on the software keyboard too.
        search.onSubmit = { [overlay] in overlay.acceptSelected() }

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        // No chrome inside the card — the family's rule. The one line this card DOES draw is the rule
        // under the query field, and it is earned: the results scroll UNDER the field.
        table.separatorStyle = .none
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = Slate.Metric.heightRowTall
        table.keyboardDismissMode = .none
        // Rows must not touch the card's own edge — a row clipped flush against the rim reads as a
        // rendering fault rather than as "there is more below".
        table.contentInset = UIEdgeInsets(
            top: Slate.Metric.space2, left: 0, bottom: Slate.Metric.space2, right: 0,
        )
        table.register(PhonePaletteRowCell.self, forCellReuseIdentifier: PhonePaletteRowCell.reuseID)
        table.register(
            PhonePaletteHeaderCell.self, forCellReuseIdentifier: PhonePaletteHeaderCell.reuseID,
        )
        table.dataSource = dataSource

        let rule = SlateCardSeparatorView(frame: .zero)
        let column = UIStackView(arrangedSubviews: [search, rule, table])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // The viewport stops at ``PaletteMetrics/resultsMaxHeight``; past that the LIST scrolls instead
        // of the card growing to the height of the window. Below it the card hugs its rows, so a
        // three-result query is a small card rather than a tall one with empty paper under the rows.
        tableHeight.isActive = true

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - The live read

    /// The one tracked read: the ranked rows, the keyboard's index and the cwd badge, all INSIDE the
    /// closure. ``OverlayCoordinator/rankedResults`` is memoised behind the query, the filter, the mixer
    /// generation and the recents ring, so reading it here registers every one of those as a dependency
    /// and costs one array read per repeat.
    private func follow() {
        generation &+= 1
        let generation = generation

        var ranked: [RankedRow] = []
        var selection = 0
        var query = ""
        var badge: String?
        withObservationTracking {
            ranked = overlay.rankedResults
            selection = overlay.paletteSelection
            // ⚠️ THE QUERY IS TWO-WAY, and the second direction is not decoration: the omnibar entry
            // calls `openPalette(mode:query:)` with text, and `closePalette()` resets the query — both
            // write the coordinator without going through the field, so a one-way binding would leave
            // the field showing text the rows are no longer ranked for.
            query = overlay.paletteQuery
            badge = PalettePresentation.workingDirectoryBadge(store: store)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        // ⚠️ ONLY ON A REAL DIFFERENCE. Assigning `UITextField.text` moves the caret to the end and
        // discards any marked text an IME is mid-composition on, so a blind write on every arm — and this
        // block re-arms on a SELECTION move too — would fight the user's own typing. The write is
        // otherwise loop-free: a programmatic `text` assignment does not fire `editingChanged`, so it
        // cannot come back through `onTextChange`.
        if search.text != query { search.text = query }
        reconcile(PalettePresentation.displayRows(ranked), selection: selection, badge: badge)
    }

    private func reconcile(_ next: [PaletteDisplayRow], selection: Int, badge: String?) {
        // ⚠️ IDENTIFIERS MUST BE UNIQUE OR THE DATA SOURCE TRAPS, and this list is a MIX of catalog rows,
        // per-open snapshots and a Recents block re-`id`'d into its own namespace — five sources that
        // nothing downstream cross-checks. A duplicate would be a crash on a keystroke, so the first
        // occurrence wins and the rest are dropped: a row missing from a list is recoverable, a trap in
        // the middle of typing is not.
        var seen = Set<String>()
        let rows = next.filter { seen.insert($0.id).inserted }

        let sameRows = rows.map(\.id) == self.rows.map(\.id)
        self.rows = rows
        byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.selection = selection
        self.badge = badge

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        // A pure SELECTION move changes no row's identity, so the diff would be empty and the plate would
        // never travel — the cells have to be told to re-read. `reconfigure` keeps each cell (and its
        // scroll position); a reload would rebuild them.
        if sameRows { snapshot.reconfigureItems(rows.map(\.id)) }
        dataSource.apply(snapshot, animatingDifferences: false)

        resize()
        scrollToSelection()
    }

    /// The card hugs its rows up to the viewport cap. Measured from the row LADDER rather than from
    /// `contentSize`, which is not yet valid in the same turn the snapshot is applied.
    private func resize() {
        let content = rows.reduce(0.0) { total, row in
            total + (row.ranked.item.isSeparator
                ? PhonePaletteHeaderCell.height
                : Slate.Metric.heightRowTall)
        }
        let padded = content + table.contentInset.top + table.contentInset.bottom
        tableHeight.constant = Swift.min(padded, CGFloat(PaletteMetrics.resultsMaxHeight))
    }

    /// Keeps the keyboard's row on screen. Unconditional here — see the file header on the missing hover
    /// gate. A selection past the end (the query narrowed the list under it) scrolls nowhere rather than
    /// to the top, which is what ``PalettePresentation/selectedRowID(_:selection:)`` answering `nil`
    /// means.
    private func scrollToSelection() {
        guard let id = rows.first(where: { $0.selectableIndex == selection })?.id,
              let index = rows.firstIndex(where: { $0.id == id })
        else { return }
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
    }

    // MARK: - The rows

    private func makeDataSource() -> UITableViewDiffableDataSource<Int, String> {
        UITableViewDiffableDataSource<Int, String>(tableView: table) { [weak self] table, path, id in
            guard let self, let row = byID[id] else { return UITableViewCell() }
            let identifier = row.ranked.item.isSeparator
                ? PhonePaletteHeaderCell.reuseID
                : PhonePaletteRowCell.reuseID
            let cell = table.dequeueReusableCell(withIdentifier: identifier, for: path)
            // Both classes are REGISTERED, so the cast cannot fail — and it is written as a `guard`
            // rather than a force-cast because a wrong answer here is a blank row, not a crash in the
            // middle of typing.
            if let header = cell as? PhonePaletteHeaderCell {
                header.show(
                    row.ranked.item,
                    // The pill hangs off the ONE header that owns it, matched by the category's own
                    // label — never "whichever separator sorts first", which mislabelled a Recents
                    // header before the Working Directory section existed.
                    badge: PalettePresentation.headerOwnsWorkingDirectoryBadge(row.ranked.item.title)
                        ? badge
                        : nil,
                )
            } else if let action = cell as? PhonePaletteRowCell {
                action.show(
                    row.ranked,
                    selected: row.selectableIndex == selection,
                    toggled: toggledState(row.ranked.item),
                )
            }
            return cell
        }
    }

    // MARK: - The keyboard

    /// The full navigation vocabulary, following the platform's list idioms: ↑/↓ step, ⌘↑/⌘↓ jump to the
    /// ends (the table-view standard), ⇞/⇟ stride one viewport of rows (the VS Code palette page), and
    /// ⌃P/⌃N step via the text system's own previous/next pair — the chords every terminal user's fingers
    /// already know. Home/End are deliberately NOT taken: in a focused query field they belong to the
    /// caret, and stealing them would break editing the search text.
    ///
    /// ⌘↩ chains — it runs the row and LEAVES the card up — while a plain ↩ runs and closes, and the two
    /// cannot both live here: plain Return is the field's own submit (see ``build()``), so only the
    /// modified form is declared as a command and the pair can never double-fire.
    ///
    /// ⚠️ A HELD ARROW STEPS ONCE, and that is a HOLE rather than a choice — the same one
    /// ``PhoneCommandNavigator`` records, for the same reason. The deleted card ran held keys through
    /// `OverlayKeyRepeat`, a whitelist typed on `KeyEquivalent` and `KeyPress.Phases`, and docs/62 §7
    /// item 1 does not port it: it MERGES into `rust/slopdesk-workspace::key_repeat`, so the overlays
    /// become a second consumer of the hardware latch the terminal already drives rather than a second
    /// repeat policy with the same name. Until that stage lands, a private clock here would be exactly
    /// the parallel the merge exists to end.
    override var keyCommands: [UIKeyCommand]? {
        [
            command(UIKeyCommand.inputUpArrow, #selector(moveUp)),
            command(UIKeyCommand.inputDownArrow, #selector(moveDown)),
            command(UIKeyCommand.inputUpArrow, #selector(moveToFirst), .command),
            command(UIKeyCommand.inputDownArrow, #selector(moveToLast), .command),
            command(UIKeyCommand.inputPageUp, #selector(pageUp)),
            command(UIKeyCommand.inputPageDown, #selector(pageDown)),
            command("p", #selector(moveUp), .control),
            command("n", #selector(moveDown), .control),
            command("\r", #selector(acceptKeepingOpen), .command),
            .slateCancel(action: #selector(cancel)),
        ]
    }

    /// ⚠️ `wantsPriorityOverSystemBehavior` IS THE WHOLE POINT for the arrows. The query field is the
    /// first responder, and UIKit gives it the arrow keys for caret movement before a key command on an
    /// ancestor ever sees them — so without this flag ↑/↓ would silently move the text cursor in an empty
    /// field while the list stood still.
    private func command(
        _ input: String, _ action: Selector, _ modifiers: UIKeyModifierFlags = [],
    ) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// One ⇞/⇟ stride: the rows one full results viewport shows, derived on the far side from the SAME
    /// number that sizes the viewport — so re-tuning the card re-tunes the page rather than leaving a
    /// stride that no longer matches what the eye just skipped.
    private var pageStride: Int {
        PaletteMetrics.pageStride(rowHeight: Double(Slate.Metric.heightRowTall))
    }

    @objc
    private func moveUp() { overlay.moveSelection(-1) }
    @objc
    private func moveDown() { overlay.moveSelection(1) }
    @objc
    private func moveToFirst() { overlay.moveSelectionToFirst() }
    @objc
    private func moveToLast() { overlay.moveSelectionToLast() }
    @objc
    private func pageUp() { overlay.moveSelection(-pageStride) }
    @objc
    private func pageDown() { overlay.moveSelection(pageStride) }
    @objc
    private func acceptKeepingOpen() { overlay.acceptSelectedKeepingOpen() }
    @objc
    private func cancel() { overlay.closePalette() }
}

// MARK: - Tapping a row

extension PhonePaletteCardView: UITableViewDelegate {
    func tableView(_: UITableView, shouldHighlightRowAt path: IndexPath) -> Bool {
        guard let row = rows[safe: path.row] else { return false }
        // A separator hugs the row under it and never highlights or runs.
        return !row.ranked.item.isSeparator
    }

    func tableView(_ table: UITableView, didSelectRowAt path: IndexPath) {
        table.deselectRow(at: path, animated: false)
        guard let row = rows[safe: path.row], !row.ranked.item.isSeparator else { return }
        overlay.run(row.ranked.item)
    }

    func tableView(_: UITableView, heightForRowAt path: IndexPath) -> CGFloat {
        guard let row = rows[safe: path.row] else { return Slate.Metric.heightRowTall }
        return row.ranked.item.isSeparator
            ? PhonePaletteHeaderCell.height
            : Slate.Metric.heightRowTall
    }
}

/// Indexing a live list from a table-view callback: the delegate can be asked about a path from the frame
/// BEFORE the snapshot that shrank the list, and a bare subscript would trap there rather than draw
/// nothing.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - The section header

/// An ALL-CAPS section header, with the contextual WORKING DIRECTORY pill on the one header that owns it.
///
/// Headers SURVIVE here, unlike in the ⌃⇥ switcher where they were deleted. The rule is the same in both
/// places — a header earns its line only when consecutive rows share it — and the two surfaces simply
/// answer it differently: the switcher's order is a recency ring, so projects interleave and a header
/// degenerates into a caption per row, while the palette's results are ranked WITHIN category and its rows
/// genuinely arrive in runs.
@MainActor
final class PhonePaletteHeaderCell: UITableViewCell {
    static let reuseID = "palette.header"
    /// Shorter than a row: a header is a label over a run, not a thing to land on.
    static let height = Slate.Metric.heightRow

    /// ⚠️ THE CAPS LABEL IS REPLACED RATHER THAN RE-TEXTED, and that is ``SlateCapsLabelView``'s
    /// contract rather than a preference: it lays its title out as an `attributedText` carrying the
    /// instrument face's TRACKING, so assigning `.text` on a recycled cell would silently drop the kern
    /// and leave one header set tighter than its neighbours. A section header is one view in a list of
    /// a dozen, so minting a fresh one per configure costs nothing measurable.
    private var caps = SlateCapsLabelView("")
    private let pill = PhonePaletteCwdBadgeView()
    private let row = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        // Mirrors the action row's leading ✓/icon gutter so the uppercase header text shares the row
        // LABELS' left margin — the headers are FLUSH with the row labels, with the ✓ gutter to their
        // LEFT. A header carries no glyph, so this is an empty placeholder and only its width matters.
        let gutter = UIView()
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.widthAnchor.constraint(equalToConstant: PhonePaletteRowCell.gutterWidth).isActive = true

        let gap = UIView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.space2).isActive = true

        // The section label always wins the layout: a long cwd path truncates, never the header it sits on.
        caps.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [gutter, caps, gap, pill] as [UIView] { row.addArrangedSubview(view) }
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        // `space3` is the action row's INNER padding and `space2` its OUTER inset; together with the
        // gutter and the stack's own spacing the header text lands at the EXACT x of a row label, so
        // headers and labels are flush. The trailing side mirrors it, so the pill's right edge lines up
        // with the keycap column instead of jutting past it.
        let inset = Slate.Metric.space3 + Slate.Metric.space2
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ item: PaletteItem, badge: String?) {
        if caps.text != item.title.uppercased() {
            let index = row.arrangedSubviews.firstIndex(of: caps) ?? 1
            row.removeArrangedSubview(caps)
            caps.removeFromSuperview()
            caps = SlateCapsLabelView(item.title)
            caps.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.insertArrangedSubview(caps, at: index)
        }
        pill.show(badge)
        isAccessibilityElement = true
        accessibilityLabel = badge.map { "\(item.title), \($0)" } ?? item.title
        accessibilityTraits = .header
    }
}

/// The contextual cwd pill on the WORKING DIRECTORY header.
@MainActor
final class PhonePaletteCwdBadgeView: UIView {
    private let glyph = UIImageView()
    private let path = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Overlay.plate
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = UIImage(
            systemName: "folder",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.small),
        )
        glyph.tintColor = Slate.Native.Overlay.secondary
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        path.translatesAutoresizingMaskIntoConstraints = false
        path.font = .systemFont(ofSize: Slate.Typeface.small)
        path.textColor = Slate.Native.Overlay.secondary
        path.numberOfLines = 1
        // HEAD-truncated so the leaf — the directory you are actually in — stays visible when the pill
        // shrinks. The default tail would drop the most meaningful part of the path.
        path.lineBreakMode = .byTruncatingHead

        let row = UIStackView(arrangedSubviews: [glyph, path])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// `nil` hides the pill outright — a pane whose directory the host has not answered for yet has NO
    /// badge, rather than an empty one.
    func show(_ text: String?) {
        path.text = text
        isHidden = text == nil
    }
}

// MARK: - The action row

/// One verb (or one pane jump): the ✓ gutter, the fzf-marked title, the subtitle it may carry, and the
/// chord's keycap.
@MainActor
final class PhonePaletteRowCell: UITableViewCell {
    static let reuseID = "palette.row"
    /// The leading ✓ gutter. A fixed rung rather than a metric because it is a GLYPH COLUMN — its job is
    /// to hold the checkmark and to set the x every title and every header shares.
    static let gutterWidth: CGFloat = 20

    private let plate = UIView()
    private let check = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private var keycap: SlateKeycapView?
    private let trailing = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        plate.translatesAutoresizingMaskIntoConstraints = false
        SlateSelectionPlateSurface.install(on: plate)
        contentView.addSubview(plate)

        // The ✓ is set in the READING ink, not an accent — a checkmark already means one thing, and
        // colouring it says nothing more.
        check.translatesAutoresizingMaskIntoConstraints = false
        check.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.footnote, weight: .semibold,
            ),
        )
        check.tintColor = Slate.Native.Overlay.primary
        check.contentMode = .center
        check.widthAnchor.constraint(equalToConstant: Self.gutterWidth).isActive = true

        title.translatesAutoresizingMaskIntoConstraints = false
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        // The subtitle (a PANES row's place line — verbs carry none) rides beside the title in the
        // secondary ink: identically-titled panes are told apart by WHERE they live. Head-truncated so a
        // squeezed path keeps its leaf.
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: Slate.Typeface.small)
        subtitle.textColor = Slate.Native.Overlay.secondary
        subtitle.numberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let gap = UIView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.space2).isActive = true

        // The keycap slot. A stack rather than a stored optional view swapped in and out, so a recycled
        // cell that has no chord simply holds an empty run instead of leaving a stale cap behind.
        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = Slate.Metric.space2
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [check, title, subtitle, gap, trailing])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(row)
        NSLayoutConstraint.activate([
            // The plate is inset from the card's edge; the row's own padding sits inside it.
            plate.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space2,
            ),
            plate.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            row.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -Slate.Metric.space3),
            row.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ ranked: RankedRow, selected: Bool, toggled: Bool) {
        let item = ranked.item
        SlateSelectionPlateSurface.apply(selected, to: plate)
        check.isHidden = !toggled
        title.attributedText = Self.markedTitle(ranked, selected: selected)
        subtitle.text = item.subtitle
        subtitle.isHidden = (item.subtitle ?? "").isEmpty

        // ONE cap for the whole chord ("⇧⌘L"), not a cap per glyph: the modifiers are not separate keys
        // to hunt for, they are one gesture, and a row of little boxes reads as four things to do.
        if let shortcut = item.shortcut, !shortcut.isEmpty {
            if let cap = keycap, cap.text == shortcut {
                cap.lit = selected
            } else {
                keycap.map { trailing.removeArrangedSubview($0)
                    $0.removeFromSuperview()
                }
                let cap = SlateKeycapView(label: shortcut, lit: selected)
                keycap = cap
                trailing.addArrangedSubview(cap)
            }
        } else {
            keycap.map { trailing.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            keycap = nil
        }

        isAccessibilityElement = true
        accessibilityLabel = [item.title, item.subtitle, item.shortcut]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        accessibilityTraits = .button
    }

    /// The row title with the fzf-matched code-point runs marked.
    ///
    /// The mark is CONTRAST, not colour: the matched run keeps the reading ink at semibold while the
    /// letters around it step back to `secondary`, so what the query hit reads as LIT rather than as
    /// tinted. It was the system accent, which put the one blue thing on an otherwise monochrome card —
    /// and the one PINK thing on a machine whose accent is pink.
    ///
    /// WHERE the cuts fall is ``FuzzyMatcher/runs(of:ranges:)``'s, shared with the Mac's palette row and
    /// with both halves of Open Quickly; the ink is this half's. Every run goes through the nerd-aware
    /// splice so a PANES row's private-use glyph draws from the bundled symbols face INSIDE the highlight
    /// run too.
    private static func markedTitle(_ ranked: RankedRow, selected: Bool) -> NSAttributedString {
        // The selected row's title goes HEAVIER, never coloured — the family's rule that importance is
        // light and weight, not hue.
        let resting: UIFont = .systemFont(
            ofSize: Slate.Typeface.body, weight: selected ? .medium : .regular,
        )
        let lit: UIFont = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        let runs = FuzzyMatcher.runs(of: ranked.item.title, ranges: ranked.titleRanges)
        guard runs.count > 1 else {
            return .slateNerdAware(
                ranked.item.title, font: resting, color: Slate.Native.Overlay.primary,
            )
        }
        let spliced = NSMutableAttributedString()
        for run in runs {
            spliced.append(.slateNerdAware(
                run.text,
                font: run.matched ? lit : resting,
                color: run.matched ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary,
            ))
        }
        return spliced
    }
}
#endif
