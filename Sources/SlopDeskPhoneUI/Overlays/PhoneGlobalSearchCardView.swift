// PhoneGlobalSearchCardView — the phone's ⇧⌘F cross-tab results surface, in UIKit (docs/62 stage F).
//
// The UIKit half of the deleted `GlobalSearchView`: a query bar over a flat, two-level list — a
// collapsible header per tab, its hit rows under it, each excerpt marked where the query landed. It is
// the palette's shape with the keyboard cursor taken away: there is no selected row here, and on a
// pointer device the POINTER is the selection, which is why hover lifts a row onto the same plate a
// palette's keyboard selection takes.
//
// THE MAC DRAWS ITS OWN (``SlopDeskMacUI/MacGlobalSearchView``, an `NSPanel` over the workspace). What
// the two halves share is everything that is not arrangement: ``GlobalSearchController`` runs every
// match (never a second matcher), ``WorkspaceStore/runGlobalSearch`` owns the query and the flags,
// ``GlobalSearchCollapseState`` is the disclosure reducer, and ``GlobalSearchPresentation`` cuts the
// excerpt around its highlight, words the two zero states and gates the summary line. The excerpt cut
// matters most: a UTF-16 range that lands inside a surrogate pair has no `String.Index`, and a half that
// re-wrote that guard would eventually trap on the one scrollback line containing an emoji.
//
// ⚠️ IT FILLS, WHERE EVERY OTHER SUMMONED CARD HUGS. ``GlobalSearchMetrics`` sizes the Mac's panel and
// says outright that the phone takes the whole sheet instead — a results surface on a screen where there
// is no "behind" has nothing to leave uncovered. ``PhoneOverlayCardHostView`` therefore pins this one
// card to its safe area rather than centring it, which is also what gives the table a height at all: a
// `UITableView` has no intrinsic size, so a hugging card would collapse to nothing.
//
// ⚠️ THE MODE PILLS ARE ``FindTogglePill``, MOUNTED — never a second chip drawn to match. "The find bar
// and the global-search query bar render the pills identically" is a locked invariant, and the way it
// survives is that both surfaces build the SAME control from the SAME ``FindModePill`` values on the
// SAME ``FindBarMetrics/touch`` rung. WHICH pills is ``FindModePill/globalSearch``'s answer: two of the
// find bar's three, because the cross-tab search runs over a scrollback mirror rather than over
// libghostty's buffer and the two engines do not agree about what a word boundary is.
//
// ⚠️ A RELOAD, NOT A DIFF, and it is the opposite call from the palette's on purpose. That list is
// re-RANKED between keystrokes — most rows survive, so a diff moves a handful of cells and keeps the
// scroll position. This one is re-SEARCHED: every hit is a fresh match over a fresh scan, hits carry no
// identity worth threading (a pane, a line and a column that all shift as the query narrows), and there
// are thousands of them. Diffing that per character costs more than the visible cells cost to rebuild,
// and the scroll position it would preserve is a position in a list that no longer exists.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class PhoneGlobalSearchCardView: UIView {
    private let store: WorkspaceStore
    private let overlay: OverlayCoordinator

    /// No magnifier: the query text is flush-left (`global-search.png`), and no in-bar ✕ either — the
    /// dismissal is the host's floor and, on a hardware keyboard, Esc.
    private let search = SlateSearchBarView(
        prompt: GlobalSearchPresentation.queryPrompt, showsMagnifier: false,
    )
    private let pills: [FindModePill: FindTogglePill]
    private let summary = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)

    /// The live query and flags. MIRRORS of the store's retained ones, restored on the way in so a
    /// re-open shows the last search rather than a blank field over stale results.
    private var query = ""
    /// Which mode chips are lit, and what a tap on one means — ``OverlayFindModes``. The pill→flag map
    /// and the "whole-word is not offered on a scrollback mirror" rule are ITS, so the Mac's panel
    /// cannot answer either question differently.
    private var modes = OverlayFindModes()
    /// Which tab groups are folded shut. Keyed by ``PaneID``, so a live re-run that re-orders or drops
    /// groups carries the intent to the panes that survived and lets a vanished one's id fall away —
    /// never collapsing the WRONG group.
    private var collapse = GlobalSearchCollapseState()

    /// The list, already flattened into what the table draws.
    private var lines: [PhoneGlobalSearchRowCell.Line] = []
    /// Set once the card has restored itself, so a view that leaves a window and comes back does not
    /// re-seed the field from the store over what the user has since typed.
    private var hasBegun = false

    init(store: WorkspaceStore, overlay: OverlayCoordinator) {
        self.store = store
        self.overlay = overlay
        // Built from a LOCAL and only then stored: a class initialiser may not read `self` before
        // `super.init`, and the tray below needs the pills already made.
        pills = Dictionary(
            uniqueKeysWithValues: FindModePill.globalSearch.map {
                ($0, FindTogglePill($0, plate: CGFloat(FindBarMetrics.touch.plate)))
            },
        )
        super.init(frame: .zero)
        build()
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

        search.onTextChange = { [weak self] text in
            self?.query = text
            self?.rerun()
        }
        // ↩ re-runs and stays: there is no selected row to accept, so the only thing Return can mean on
        // this surface is "search now" — which every keystroke already did.
        search.onSubmit = { [weak self] in self?.rerun() }
        // The query sinks into the shared field plate, the same recipe the Connect card's inputs take,
        // so an editable field looks the same on every overlay. The pills stay OUTSIDE it — siblings in
        // the row, individually outlined chips with gaps between, never a shared backing tray.
        //
        // ⚠️ THE WHOLE BAR IS THE PLATE HERE, where the declarative original plated the text LINE and the
        // AppKit twin plates a ~24pt field. Deliberate, and it is the touch target that decides: this bar
        // is `Slate.Metric.heightInput` tall by its own constraint, and a well drawn inside it would put a
        // hairline through the middle of the region a thumb has to hit. The published text insets do not
        // apply for the same reason — the bar already inset its field on the family's own padding.
        SlateFieldPlateSurface.apply(to: search)

        // A TRANSPARENT tray: the chips delineate themselves, so the container only spaces them. The
        // same shape ``TerminalFindBarView`` builds around the same pills — which is the locked
        // invariant, not a coincidence.
        let tray = UIStackView()
        tray.axis = .horizontal
        tray.spacing = Slate.Metric.space1
        for mode in FindModePill.globalSearch {
            guard let pill = pills[mode] else { continue }
            pill.onToggle = { [weak self] in self?.toggle(mode) }
            tray.addArrangedSubview(pill)
        }

        let queryRow = UIStackView(arrangedSubviews: [search, tray])
        queryRow.axis = .horizontal
        queryRow.alignment = .center
        queryRow.spacing = Slate.Metric.space2
        queryRow.isLayoutMarginsRelativeArrangement = true
        queryRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Slate.Metric.space4, bottom: 0, trailing: Slate.Metric.space4,
        )

        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.font = .monospacedDigitSystemFont(
            ofSize: Slate.Typeface.footnote, weight: .regular,
        )
        summary.textColor = Slate.Native.Overlay.secondary
        summary.numberOfLines = 1
        // ⚠️ THE BOX IS KEPT WHETHER OR NOT THERE IS A COUNT IN IT. An empty `UILabel` has an intrinsic
        // height of ZERO — the AppKit twin's text field keeps its frame, this does not — so without the
        // pin the row would collapse to its own margins the moment the summary emptied, and the whole
        // list under it would jump a line on the first and last keystroke of a search.
        summary.heightAnchor.constraint(
            equalToConstant: (summary.font ?? .systemFont(ofSize: Slate.Typeface.footnote)).lineHeight,
        ).isActive = true
        let summaryRow = UIStackView(arrangedSubviews: [summary])
        summaryRow.axis = .horizontal
        summaryRow.isLayoutMarginsRelativeArrangement = true
        summaryRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space2, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space2, trailing: Slate.Metric.space4,
        )

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        // No chrome inside the card — the family's rule. The one line this card DOES draw is the rule
        // under the query field, and it is earned: the results scroll UNDER the field.
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        // ⚠️ THE KEYBOARD MUST NOT GO AWAY ON A SCROLL. The query field is this surface's whole input,
        // and a software keyboard that dismissed itself when the user flicked the results would have to
        // be summoned again by tapping the field — on a card whose every keystroke re-runs the search.
        table.keyboardDismissMode = .none
        table.register(
            PhoneGlobalSearchRowCell.self, forCellReuseIdentifier: PhoneGlobalSearchRowCell.reuseID,
        )
        // Rows must not touch the card's own edge — a row clipped flush against the rim reads as a
        // rendering fault rather than as "there is more below".
        table.contentInset = UIEdgeInsets(
            top: Slate.Metric.space1, left: 0, bottom: Slate.Metric.space1, right: 0,
        )

        let rule = SlateCardSeparatorView(frame: .zero)
        let column = UIStackView(arrangedSubviews: [queryRow, rule, summaryRow, table])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate(column.slateEdges(of: self))
        NSLayoutConstraint.activate([
            queryRow.heightAnchor.constraint(equalToConstant: Slate.Metric.heightInput),
        ])
    }

    // MARK: - Coming up

    /// Restores the last search and draws. `didMoveToWindow` rather than an `onAppear` twin, because a
    /// `UIView` has no such callback and this is the one UIKit gives that means "you are mounted": the
    /// field's own opening focus rides the same edge inside ``SlateSearchBarView``.
    ///
    /// It does NOT re-run the search. The store still holds the last result set, and re-running would
    /// spend a full cross-tab scan to arrive at what is already on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasBegun else { return }
        hasBegun = true
        query = store.globalSearchQuery
        modes = OverlayFindModes(
            caseSensitive: store.globalSearchCaseSensitive, isRegex: store.globalSearchRegex,
        )
        search.text = query
        for (mode, pill) in pills { pill.setOn(modes.isOn(mode)) }
        follow()
    }

    // MARK: - The live read

    /// The one tracked read, and it reads ONE property: the result set the store publishes. Everything
    /// else this card draws is either its own mirror (the query, the flags, the collapse map) or is
    /// derived from those — which is exactly why ``rerun()`` and ``activate(_:)`` call ``draw()``
    /// THEMSELVES rather than waiting for an edge that will not come.
    ///
    /// ``ObservationFollow/arm(_:read:apply:)`` is the one spelling of the re-arm (docs/62 §3.1): the
    /// weak owner, the teardown guard and the reads-inside/work-outside split are all structural here,
    /// and the arming call takes the first reading, so there is no "apply once, then follow" to get in
    /// the wrong order.
    private func follow() {
        ObservationFollow.arm(
            self,
            read: { $0.store.globalSearch },
            apply: { card, _ in card.draw() },
        )
    }

    private func draw() {
        // EMPTIED rather than hidden: a hidden label in a stack gives its space back, and its box is
        // pinned above for the same reason — the results list must not jump a line as the first
        // keystroke of a search brings the count into being and the last one takes it away.
        summary.text = GlobalSearchPresentation.summary(store.globalSearch, query: query) ?? ""
        drawRows(store.globalSearch?.groups ?? [])
    }

    /// The list, flattened: a header line per group and a hit line per visible hit.
    ///
    /// Flat because that is what it IS — the groups are headings over one continuous run of rows, not
    /// nested containers — and because a folded group then costs exactly the rows it hides.
    private func drawRows(_ groups: [GlobalSearchGroup]) {
        var next: [PhoneGlobalSearchRowCell.Line] = []
        for group in groups {
            next.append(.group(group, collapsed: collapse.isCollapsed(group.paneID)))
            guard collapse.showsHits(group.paneID) else { continue }
            next.append(contentsOf: group.hits.map { .hit($0) })
        }
        if next.isEmpty {
            // A HINT before anything is typed, a VERDICT once something was — the distinction is the
            // whole point of the far side having two lines, and "no results" under an empty field would
            // report a failure nobody asked for.
            next = [.empty(GlobalSearchPresentation.emptyStateLine(query: query))]
        }
        lines = next
        table.reloadData()
    }

    // MARK: - The query and the pills

    private func rerun() {
        store.runGlobalSearch(query: query, caseSensitive: modes.caseSensitive, isRegex: modes.isRegex)
        // Straight to `draw()`, not left to the observation edge: the summary line and the zero state
        // are worded from the QUERY as well as from the results, and a keystroke that leaves the result
        // set identical — clearing the last character of a search that already matched nothing — moves
        // nothing the tracker is watching.
        draw()
    }

    /// A chip. `.wholeWord` moves nothing — see the file header on the two engines' word boundaries —
    /// so the guard is what stops an inert tap from re-running the query, for a case
    /// ``FindModePill/globalSearch`` cannot produce in the first place.
    private func toggle(_ mode: FindModePill) {
        guard modes.toggle(mode) else { return }
        pills[mode]?.setOn(modes.isOn(mode))
        rerun()
    }

    /// A group header folds; a hit row JUMPS and closes the card behind it.
    private func activate(_ line: PhoneGlobalSearchRowCell.Line) {
        switch line {
        case let .group(group, _):
            // A local value type, invisible to `Observation` — so the redraw is this line's own, the
            // same way `rerun()`'s is.
            collapse.toggle(group.paneID)
            draw()
        case let .hit(hit):
            store.jumpToGlobalSearchResult(hit)
            overlay.closeGlobalSearch()
        case .empty:
            break
        }
    }

    // MARK: - The keyboard

    /// Esc only. There is no keyboard cursor down this list to move, so the palette's arrow vocabulary
    /// has nothing to steer — the arrows stay with the query field's caret, where they belong.
    ///
    /// ⚠️ IT HANGS ON THE CARD, not on the field. `keyCommands` are dispatched from the FIRST RESPONDER
    /// upwards, and the responder while this card is up is the query field inside it, so a command
    /// declared anywhere but on an ANCESTOR of that field is never reached.
    override var keyCommands: [UIKeyCommand]? {
        [.slateCancel(action: #selector(cancel))]
    }

    @objc
    private func cancel() { overlay.closeGlobalSearch() }
}

// MARK: - The list

extension PhoneGlobalSearchCardView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { lines.count }

    func tableView(_ table: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = table.dequeueReusableCell(
            withIdentifier: PhoneGlobalSearchRowCell.reuseID, for: path,
        )
        // The class is REGISTERED, so the cast cannot fail — written as a conditional rather than a
        // force-cast because a wrong answer here should be a blank row, not a crash mid-search.
        if let row = cell as? PhoneGlobalSearchRowCell, let line = lines[safe: path.row] {
            row.show(line)
        }
        return cell
    }

    /// A header sits TALLER than the hits under it: the extra air is the space between one tab's
    /// results and the next's, and the zero-state sentence takes the same rung because it stands where
    /// a header would.
    func tableView(_: UITableView, heightForRowAt path: IndexPath) -> CGFloat {
        switch lines[safe: path.row] {
        case .hit: Slate.Metric.heightRow
        default: Slate.Metric.heightRowTall
        }
    }

    /// The zero-state sentence is not a control and must not light up under a finger.
    func tableView(_: UITableView, shouldHighlightRowAt path: IndexPath) -> Bool {
        switch lines[safe: path.row] {
        case .empty,
             .none: false
        default: true
        }
    }

    func tableView(_ table: UITableView, didSelectRowAt path: IndexPath) {
        table.deselectRow(at: path, animated: false)
        guard let line = lines[safe: path.row] else { return }
        activate(line)
    }
}

/// Indexing a live list from a table-view callback: the delegate can be asked about a path from the frame
/// BEFORE the reload that shrank the list, and a bare subscript would trap there rather than draw nothing.
///
/// FILE-PRIVATE, and deliberately not lifted to the target. Two other files already declare their own
/// (`PhonePaletteCardView`, `PhoneSimulatorDeviceList`) — a module-wide one would be a general extension
/// on `Array` minted for three call sites, which is exactly the kind of ambient API that turns into an
/// obligation. Three copies of two lines cost less than one shared name every future file inherits.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - One row

/// A group header, a hit, or the zero-state sentence — ONE cell class with three modes, the way the
/// Mac's row is one view with three.
///
/// Three cell classes was the obvious alternative and it is the wrong shape here: the three lines are
/// the same row — a plate, a leading glyph slot, a single line of text, a trailing slot — differing in
/// which slots are filled, how far the content is indented and what the text is set in. Split apart,
/// the plate and the indent would be written three times and would drift the first time either moved.
@MainActor
final class PhoneGlobalSearchRowCell: UITableViewCell {
    static let reuseID = "PhoneGlobalSearchRow"

    /// What a row IS. The associated values are exactly what drawing and activating each kind needs,
    /// which is what lets the card hand one value to both.
    enum Line {
        case group(GlobalSearchGroup, collapsed: Bool)
        case hit(GlobalSearchHit)
        case empty(String)
    }

    /// The row's own plate — the surface hover lifts, inset from the card's edge so the lift reads as a
    /// row rather than as a full-bleed band.
    private let plate = UIView()
    private let disclosure = UIImageView()
    private let terminal = UIImageView()
    private let text = UILabel()
    private let arrow = UIImageView()
    private let content = UIStackView()
    /// The one constraint the three modes move: how far in from the plate's edge the line starts. The
    /// plate is full width either way — it is what lifts — so the indent moves the CONTENT, not the
    /// surface under it.
    ///
    /// `lazy`, not an implicitly-unwrapped optional: the constraint is minted from two stored views and
    /// so cannot be built at the declaration, but it is never absent either — and an IUO would say it
    /// might be, in the one place a crash would be silent until a cell first drew.
    private lazy var contentLeading = content.leadingAnchor.constraint(
        equalTo: plate.leadingAnchor, constant: Slate.Metric.space1,
    )

    /// Only a HIT lifts under the pointer and only a hit shows the jump arrow: a header is a disclosure
    /// control and the zero state is a sentence.
    private var lifts = false
    /// iPadOS with a trackpad has hover exactly as the Mac does; a touch-only device never sets it, and
    /// the row then simply never lifts. It is NOT dropped as "no hover on this platform" the way the
    /// toast's is — this surface is the one where hover carries meaning the phone cannot express
    /// otherwise, because there is no keyboard cursor to mark the row the eye is on.
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            refreshLift()
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // The card is the surface; a cell that painted its own would draw a band across the paper.
        contentView.backgroundColor = .clear
        selectionStyle = .none

        plate.translatesAutoresizingMaskIntoConstraints = false
        SlateSelectionPlateSurface.install(on: plate)
        contentView.addSubview(plate)

        for image in [disclosure, terminal, arrow] {
            image.translatesAutoresizingMaskIntoConstraints = false
            image.contentMode = .center
            image.tintColor = Slate.Native.Overlay.secondary
            image.setContentHuggingPriority(.required, for: .horizontal)
            image.setContentCompressionResistancePriority(.required, for: .horizontal)
            image.isAccessibilityElement = false
        }
        // `apple.terminal` is the `>_` PROMPT-BOX glyph, not an Apple-logo mark, and it is the
        // non-deprecated spelling of the symbol the bare `terminal` name used to carry.
        terminal.image = UIImage(
            systemSymbol: .appleTerminal,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )
        arrow.image = UIImage(
            systemSymbol: .arrowRight,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )
        arrow.tintColor = Slate.Native.Overlay.tertiary

        text.numberOfLines = 1
        text.lineBreakMode = .byTruncatingTail
        // The line gives way before any of the glyph slots do: an excerpt that ran long must lose its
        // tail, never push the jump arrow off the row.
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Slate.Metric.space2
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [disclosure, terminal, text, arrow] { content.addArrangedSubview(view) }
        plate.addSubview(content)

        contentLeading = content.leadingAnchor.constraint(
            equalTo: plate.leadingAnchor, constant: Slate.Metric.space1,
        )
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space3,
            ),
            plate.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentLeading,
            content.trailingAnchor.constraint(
                equalTo: plate.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            content.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            // The disclosure keeps a FIXED slot whether it is drawn or not, so a header's terminal
            // glyph and a hit's excerpt below it do not step sideways as groups fold.
            disclosure.widthAnchor.constraint(equalToConstant: Slate.Typeface.body),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ A RECYCLED CELL KEEPS ITS HOVER, and a stale one is a row lit under a pointer that is nowhere
    /// near it. UIKit hands the cell back without a `hoverGestureRecognizer` end event, so the reset is
    /// this callback's — the plate's own state follows from it.
    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
        refreshLift()
    }

    // MARK: Drawing

    func show(_ line: Line) {
        switch line {
        case let .group(group, collapsed): showGroup(group, collapsed: collapsed)
        case let .hit(hit): showHit(hit)
        case let .empty(message): showEmpty(message)
        }
        refreshLift()
    }

    private func showGroup(_ group: GlobalSearchGroup, collapsed: Bool) {
        lifts = false
        arrow.isHidden = true
        disclosure.isHidden = false
        terminal.isHidden = false
        // A header sits SHALLOWER than the hits under it: the indent is what makes the group a group.
        contentLeading.constant = Slate.Metric.space1
        // The disclosure control the spec puts to the LEFT of the header — `▸` shut, `▾` open.
        disclosure.image = UIImage(
            systemSymbol: collapsed ? .chevronRight : .chevronDown,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .semibold,
            ),
        )
        text.font = Slate.Typeface.instrumentNative(Slate.Typeface.footnote, weight: .medium)
        text.textColor = Slate.Native.Overlay.secondary
        text.attributedText = nil
        text.text = group.groupTitle
        isAccessibilityElement = true
        accessibilityLabel = group.groupTitle
        // The fold state is COPY, and copy is the far side's: both halves said this sentence themselves
        // before ``GlobalSearchPresentation/disclosureState(collapsed:)`` existed.
        accessibilityValue = GlobalSearchPresentation.disclosureState(collapsed: collapsed)
        accessibilityTraits = .button
    }

    private func showHit(_ hit: GlobalSearchHit) {
        lifts = true
        disclosure.isHidden = true
        terminal.isHidden = true
        arrow.isHidden = true // revealed by hover only — see `refreshLift()`
        contentLeading.constant = Slate.Metric.space3
        text.text = nil
        text.attributedText = Self.marked(GlobalSearchPresentation.excerptSlices(hit))
        isAccessibilityElement = true
        // The whole line, unmarked: the wash says "here" to the eye and has nothing to say to a reader
        // that has no eye on the row.
        accessibilityLabel = hit.excerpt
        accessibilityValue = nil
        accessibilityTraits = .button
    }

    private func showEmpty(_ message: String) {
        lifts = false
        for view in [disclosure, terminal, arrow] { view.isHidden = true }
        contentLeading.constant = Slate.Metric.space1
        text.font = .systemFont(ofSize: Slate.Typeface.body)
        text.textColor = Slate.Native.Overlay.tertiary
        text.attributedText = nil
        text.text = message
        isAccessibilityElement = true
        accessibilityLabel = message
        accessibilityValue = nil
        // A sentence, not a control: nothing to activate and nothing to announce as activatable.
        accessibilityTraits = .staticText
    }

    /// The excerpt with its matched run lit: the line in the supporting ink, the hit in the reading ink
    /// over the warn wash — the SAME mark the in-pane find draws, because a result found here and the
    /// same result found there must not be a different colour of found.
    ///
    /// WHERE the cut falls is ``GlobalSearchPresentation/excerptSlices(_:)``'s, including the case where
    /// it cannot fall anywhere: that comes back as the whole line in `before` and needs no flag here —
    /// the two outer runs take the supporting ink and the middle one is marked, so an empty middle
    /// simply marks nothing.
    private static func marked(_ excerpt: GlobalSearchExcerpt) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
        let marked = NSMutableAttributedString(
            string: excerpt.before,
            attributes: [.font: font, .foregroundColor: Slate.Native.Overlay.secondary],
        )
        marked.append(NSAttributedString(
            string: excerpt.match,
            attributes: [
                .font: font,
                .foregroundColor: Slate.Native.Overlay.primary,
                // ``Slate/Opacity/findWash``, which the Mac's results panel reads too — see the doc on
                // the rung for why the pair is the point.
                .backgroundColor: Slate.Native.Status.warn
                    .slateScalingAlpha(Slate.Opacity.findWash),
            ],
        ))
        marked.append(NSAttributedString(
            string: excerpt.after,
            attributes: [.font: font, .foregroundColor: Slate.Native.Overlay.secondary],
        ))
        return marked
    }

    // MARK: The pointer

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began,
             .changed: hovering = true
        default: hovering = false
        }
    }

    /// Hover lifts the row onto the shared selection plate — the same plate a keyboard-selected palette
    /// row takes, because on this surface the pointer IS the selection.
    private func refreshLift() {
        let lit = lifts && hovering
        SlateSelectionPlateSurface.apply(lit, to: plate)
        arrow.isHidden = !lit
    }
}
#endif
