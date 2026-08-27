// MacCommandNavigator — the Command Navigator card (⌃⌘O) over the ACTIVE pane, in AppKit.
//
// ⌃⌘O was a LIVE DEAD CHORD on the Mac until this file: `view.commandNavigator`
// (`binding_rows.rs:131`) routes through ``WorkspaceBindingRegistry`` → `WorkspaceBindingRouting` →
// ``WorkspaceStore/requestBlockNavigatorInActivePane()`` → the active pane model's
// `onRequestBlockNavigator`, which ``TerminalPaneWiring`` has always bound — to a TOGGLE on
// ``CommandNavigatorChrome/isVisible``. The phone reads that flag and mounts `CommandNavigatorView`;
// nothing on the Mac read it, so the chord was taken away from the PTY to flip a `Bool` nobody drew.
// `MacTerminalLeafView`'s own ⚠️ predicted exactly this. This is the second renderer that flag was
// always waiting for (docs/56 §3.5 step 4) — a PORT, not a fork: every decision the card makes was
// already shared, and what is here is the drawing.
//
// WHAT IT READS, and it invents no data path:
//   • the list — ``TerminalBlockModel/blocks(filter:)`` on the pane's LIVE model (no snapshot, so a
//     command that finishes while the card is up flips its own gutter in place);
//   • the ranking — ``CommandNavigatorModel/filtered(_:query:)``, the same `search_rank` every
//     search field in the app asks for;
//   • the clamp — ``ListNavigation/clampedSelection(current:delta:count:)``;
//   • the jump — ``WorkspaceStore/jumpToNavigatorBlockInActivePane(index:)``, i.e. the shared
//     `BlockJump` re-anchor, so the prompt-ordinal math is never re-derived here;
//   • the two row verbs — ``WorkspaceStore/reRunCommandInActivePane(_:)`` and
//     ``WorkspaceStore/copyBlockOutputInActivePane(index:onResult:)``, the SAME request paths the
//     terminal's context menu uses;
//   • the stars — ``TerminalBlockModel``'s bookmarks API, persisted through the wired
//     `onBookmarksChanged`;
//   • the words and the two measurements — ``CommandNavigatorPresentation`` /
//     ``CommandNavigatorMetrics`` (`SlopDeskClientCore`).
//
// THE IDIOM IS THE MAC'S SUMMONED-CARD FAMILY, read off its two nearest neighbours:
//   • the PAPER is ``MacOverlayCardView`` — the ground's cream at `radiusPanel`, the `overlayRim`
//     hairline, the palette rung of the shadow ladder — reached rather than re-cut, so this card
//     and the palette cannot end up two different papers;
//   • the KEYBOARD belongs to the FIELD and the list is steered THROUGH it (`MacPaletteView`'s
//     rule 1): `moveUp:` / `moveDown:` / `insertNewline:` / `cancelOperation:` arrive as editing
//     commands, and the two ⌘-modified chords come through `performKeyEquivalent(with:)`, which is
//     the door AppKit opens before the responder chain;
//   • the MARK on a matched run is CONTRAST, never colour — ``FuzzyMatcher/runs(of:ranges:)`` cuts
//     it and this file inks it, exactly as ``MacPaletteTitle`` does. (The phone's twin tints the run
//     with the accent; the Mac's house rule is the one written on `FuzzyMatcher.runs` itself, and
//     the palette was moved OFF the accent for it.)
//   • the STAR is ``MacPlateIconButton``, whose latched state is ink and weight rather than a hue —
//     so a starred row does not put the one amber thing on a monochrome card.
//
// IT IS PANE-LOCAL, and that is why it is not a ``MacOverlayPanelController``. The navigator floats
// over ONE pane's terminal — the active one, which is the pane the store resolved before firing —
// so its scrim is the pane's rect and not the window's, and its lifetime is the leaf's
// ``CommandNavigatorChrome`` rather than the overlay coordinator's. That also keeps the navigator
// out of `anyModalVisible`, which the chrome columns gate their hit-testing on: a card over one pane
// must not deafen the sidebar. What it DOES need from that family is the pointer shield — see
// ``MacPaneCardShield``.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // ListNavigation — the clamp all three list overlays share

// MARK: - The pointer shield's second input

/// Whether a PANE-LOCAL modal card is floating over a terminal right now.
///
/// ``TerminalPointerShield`` exists because an `NSTrackingArea` is RECT-based: it keeps firing no
/// matter what is composited above it, so a terminal under a card goes on feeding cursor positions
/// to a mouse-reporting TUI (hover highlights track the pointer THROUGH the card) and
/// focus-follows-mouse can hand the workspace away mid-card. The app root binds that shield to
/// ``OverlayCoordinator/anyModalVisible``, which answers for the WINDOW-level family and knows
/// nothing about a card mounted inside one pane — so this is the same fact, asked from the other
/// side, and the root ORs the two.
///
/// A COUNT rather than a `Bool`: `CommandNavigatorChrome` is per-pane, so two panes can each hold an
/// open navigator (open one, focus a sibling, open another), and a `Bool` cleared by the second
/// closing would unshield the first. The balance is the leaf's — one ``raise()`` per mount, one
/// ``lower()`` per unmount — because the leaf is the only object that sees both edges.
@MainActor
enum MacPaneCardShield {
    private static var mounted = 0

    /// Whether any pane-local card is up.
    static var isPresenting: Bool { mounted > 0 }

    /// A pane-local card was mounted.
    static func raise() { mounted += 1 }

    /// A pane-local card was removed. Floors at zero so an unbalanced call can never leave the
    /// terminal permanently pointer-deaf, which is the failure nobody would find.
    static func lower() { mounted = Swift.max(0, mounted - 1) }
}

// MARK: - The scrim, and the card standing on it

/// The navigator as the leaf mounts it: a pane-local dismiss floor with the paper card centred on it.
///
/// It fills the pane's surface area, so the scrim is the pane's own rect. The phone's twin spends a
/// `Rectangle().fill(Slate.State.shadow)` for the same veil and the same reason — the navigator
/// floats over THIS pane's terminal, not over the window, so it carries its own backdrop rather than
/// borrowing the window-level family's.
@MainActor
final class MacCommandNavigatorView: NSView {
    /// Clears the pane chrome's `isVisible`. Fired by Esc, by a click beside the card, and by a row
    /// that acted.
    private let onClose: () -> Void

    private let card = MacOverlayCardView(frame: .zero)
    private let content: MacCommandNavigatorCardView

    /// Whether this card has been dismissed and is only finishing its fade. See ``retire()``.
    private var retired = false

    init(model: TerminalViewModel, store: WorkspaceStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        content = MacCommandNavigatorCardView(model: model, store: store, onClose: onClose)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        addSubview(card)

        // The width is the card's own; the HEIGHT is intrinsic, so a two-row list gets a two-row card
        // rather than a full-height one padded out with nothing (the palette's rule 3, reached here
        // through Auto Layout instead of through a panel resize).
        let width = card.widthAnchor.constraint(
            equalToConstant: CommandNavigatorMetrics.panelWidth,
        )
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Arriving and leaving

    /// Fades the card in — the AppKit reading of the phone's `.transition(.opacity)` under
    /// `Slate.Anim.reveal`, which is the same curve at the same duration.
    ///
    /// Opacity ONLY, with no travel: the chips slide because they arrive at an edge of a pane that
    /// is already being read, while this lands in the middle of it — a card that flew in would drag
    /// the eye across the terminal it is about to cover.
    func reveal() {
        alphaValue = 0
        animate { self.animator().alphaValue = 1 }
    }

    /// Fades the card out and removes it when it settles.
    ///
    /// `retired` is set FIRST and gates ``hitTest(_:)``, because `alphaValue` is a drawing property:
    /// a card at alpha 0.2 still swallows the click meant for the terminal returning underneath it.
    /// The leaf forgets the card before calling this, so a second ⌃⌘O during the fade builds a fresh
    /// one rather than finding this one on its way out.
    func retire() {
        guard !retired else { return }
        retired = true
        animate({ self.animator().alphaValue = 0 }, thenRemoving: self)
    }

    /// The reveal curve around one mutation, optionally retiring a view when it settles.
    ///
    /// The completion is `@Sendable` while `removeFromSuperview` is main-actor isolated — nothing in
    /// the handler's TYPE promises which thread runs it, and AppKit always uses the main one without
    /// having annotated that — so a VIEW is passed rather than a closure, which crosses freely
    /// because a `@MainActor` class is implicitly `Sendable`. Same shape as `MacLeafChipReveal`'s.
    private func animate(_ body: @escaping () -> Void, thenRemoving retiring: NSView? = nil) {
        let curve = Slate.Motion.reveal
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            body()
        } completionHandler: {
            MainActor.assumeIsolated { retiring?.removeFromSuperview() }
        }
    }

    /// A retired card is transparent to the pointer even while it is still on screen fading.
    override func hitTest(_ point: NSPoint) -> NSView? {
        retired ? nil : super.hitTest(point)
    }

    /// The results ceiling is the pane's to cap, not only the token's: a split pane can be shorter
    /// than ``CommandNavigatorMetrics/resultsMaxHeight``, and a card taller than the surface it
    /// floats over would run out past the island's edge. Pushed rather than read so the card owns
    /// one number and the container owns where it came from.
    override func layout() {
        super.layout()
        content.heightBudget = bounds.height - 2 * Slate.Metric.space4
    }

    /// Hands the keyboard to the query field once the card is on screen.
    ///
    /// Deferred one runloop hop for the reason the find bar and the palette defer theirs: a field
    /// cannot take first responder before its window is key, and `viewDidMoveToWindow` runs while
    /// the view is still being put in place.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.content.focusQuery() }
        }
    }

    /// Esc with nothing else to answer it lands here — the responder-chain door the window-level
    /// family gets from its panel's backdrop.
    override func cancelOperation(_: Any?) {
        onClose()
    }

    override var acceptsFirstResponder: Bool { true }

    /// A click that reached the FLOOR is a click beside the card (the card is a subview and takes its
    /// own hits first), which is the dismiss gesture.
    override func mouseDown(with _: NSEvent) {
        onClose()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // `effectiveAppearance` has to be the CURRENT one while a dynamic colour resolves, or the
        // rung answers for whatever appearance happened to be drawing last.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.State.shadow.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The card's content

/// The card itself: a pre-focused query line, the status segment, the ranked list, and the foot bar.
@MainActor
final class MacCommandNavigatorCardView: NSView, NSTextFieldDelegate {
    /// The pane's live terminal model — its pure block store is this card's data source and its
    /// bookmarks API backs the star. This is the pane the card floats over (the active one).
    private let model: TerminalViewModel
    /// The live store — performs the jump, the re-run and the output copy through the shared paths.
    private let store: WorkspaceStore
    private let onClose: () -> Void

    private let magnifier = NSImageView()
    private let field = NSTextField()
    private let queryRule = MacCardRuleView()
    private let filterTray = NSStackView()
    private let filterRule = MacCardRuleView()
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let zeroState = NSTextField(labelWithString: "")
    private let footerRule = MacCardRuleView()
    private let footer = NSStackView()

    private var pills: [BlockNavigatorFilter: MacCommandNavigatorFilterPill] = [:]
    /// The row views currently in the column, in draw order — kept so a selection step moves the
    /// plate without rebuilding a list that did not change.
    private var rows: [MacCommandNavigatorRowView] = []
    /// The rows as last drawn, so the keyboard verbs act on what the eye is looking at.
    private var visible: [CommandBlock] = []

    private var query = ""
    private var filter = BlockNavigatorFilter.all
    private var selection = 0
    /// The selection the viewport was last scrolled for. `-1` is "never", which no index can be, so
    /// the first draw does not scroll a list that has not moved.
    private var lastRevealed = -1
    /// Hover→selection arbiter: a hover-driven selection must not auto-scroll, and a list scrolling
    /// under a PARKED pointer must not steal the selection. One per presentation, shared by the rows.
    private let hoverGate = HoverSelectionGate()

    private var listHeight: NSLayoutConstraint?

    /// The tallest the whole card may be, pushed down by the container from the pane's height.
    var heightBudget: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard heightBudget != oldValue else { return }
            fitList()
        }
    }

    init(model: TerminalViewModel, store: WorkspaceStore, onClose: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.onClose = onClose
        super.init(frame: .zero)

        buildQueryLine()
        buildFilters()
        buildResults()
        buildFooter()
        placeParts()
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func buildQueryLine() {
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = Slate.Native.Overlay.secondary
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.body, weight: .regular,
        )
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        addSubview(magnifier)

        // No bezel and no background: the CARD is the surface, and a second plate drawn inside it
        // would read as an input sunk into paper rather than as the card's own first line (the
        // palette's query line, not the find bar's well).
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Overlay.primary
        field.placeholderString = CommandNavigatorPresentation.searchPlaceholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        queryRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(queryRule)
    }

    private func buildFilters() {
        // A TRANSPARENT tray: each pill delineates itself, so the container only spaces them.
        filterTray.orientation = .horizontal
        filterTray.alignment = .centerY
        filterTray.spacing = Slate.Metric.space1
        filterTray.translatesAutoresizingMaskIntoConstraints = false
        for segment in BlockNavigatorFilter.allCases {
            let pill = MacCommandNavigatorFilterPill(segment)
            pill.onSelect = { [weak self] in self?.choose(segment) }
            pills[segment] = pill
            filterTray.addView(pill, in: .leading)
        }
        addSubview(filterTray)

        filterRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterRule)
    }

    private func buildResults() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        // The rows must not touch the card's own edge — a row clipped flush against the rim reads as
        // a rendering fault rather than as "there is more below".
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space2, left: Slate.Metric.space2,
            bottom: Slate.Metric.space2, right: Slate.Metric.space2,
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        // The one zero-state voice for a list surface: a single centred line, text-only, no glyph.
        zeroState.alignment = .center
        zeroState.font = .systemFont(ofSize: Slate.Typeface.body)
        zeroState.textColor = Slate.Native.Overlay.tertiary
        zeroState.isSelectable = false
        zeroState.maximumNumberOfLines = 1
        column.addArrangedSubview(zeroState)
        zeroState.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow).isActive = true
        zeroState.widthAnchor.constraint(
            equalTo: column.widthAnchor, constant: -Slate.Metric.space2 * 2,
        ).isActive = true

        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = column
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // Pinned to the CLIP view's width so the rows lay out at the card's width and the scrolling
        // is vertical only — a document view left free in both axes scrolls sideways instead.
        column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    private func buildFooter() {
        footerRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerRule)

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Slate.Metric.space3
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addView(Self.hint(CommandNavigatorPresentation.navigateHint), in: .leading)
        for value in [CommandNavigatorPresentation.jumpHint, CommandNavigatorPresentation.closeHint] {
            footer.addView(Self.hint(value), in: .trailing)
        }
        addSubview(footer)
    }

    /// One foot-bar hint: what the key does, then the key itself as a ``MacKeycapView`` — the app's
    /// one cap, in the system face, so a chord in a hint and a chord in the cheat sheet read alike.
    private static func hint(_ value: CommandNavigatorHint) -> NSView {
        let label = NSTextField(labelWithString: value.label)
        label.font = .systemFont(ofSize: Slate.Typeface.small)
        label.textColor = Slate.Native.Overlay.tertiary
        label.isSelectable = false
        let cap = MacKeycapView(label: value.glyph)
        let pair = NSStackView(views: [label, cap])
        pair.orientation = .horizontal
        pair.alignment = .centerY
        pair.spacing = Slate.Metric.space1
        return pair
    }

    private func placeParts() {
        let list = scroll.heightAnchor.constraint(
            equalToConstant: CommandNavigatorMetrics.resultsMaxHeight,
        )
        listHeight = list
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            magnifier.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space2,
            ),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightInput),

            queryRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            queryRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            queryRule.topAnchor.constraint(equalTo: field.bottomAnchor),
            queryRule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            filterTray.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            filterTray.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Slate.Metric.space3,
            ),
            filterTray.topAnchor.constraint(equalTo: queryRule.bottomAnchor),
            filterTray.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),

            filterRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterRule.topAnchor.constraint(equalTo: filterTray.bottomAnchor),
            filterRule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterRule.bottomAnchor),
            list,

            footerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerRule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            footer.topAnchor.constraint(equalTo: footerRule.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Focus

    /// Pre-focuses the query field so typing lands immediately, and tints its caret the accent.
    ///
    /// The caret colour has to be set on the FIELD EDITOR — the window's shared `NSTextView`, which
    /// only exists once the field is focused — so it is a step of focusing rather than a property of
    /// the field (the find bar's `tintCaret`).
    func focusQuery() {
        guard let window, window.firstResponder !== field.currentEditor() else { return }
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = Slate.Native.accent
        }
    }

    // MARK: The live read

    /// Draws the current state and re-arms itself on everything it read.
    ///
    /// The card reads the LIVE block model rather than a snapshot, which is the whole reason this is
    /// an observation arm and not a one-shot draw: a command that finishes while the navigator is
    /// open flips its own gutter, and a command that STARTS while it is open appears.
    ///
    /// The `onChange` handler fires BEFORE the value it announces is stored, so the next render is
    /// scheduled rather than run — reading inside the callback would answer with the old value.
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
        // The pane's blocks for the active segment (newest-first) BEFORE the text filter — the pure
        // `TerminalBlockModel` query — then the shared ranking on top of it.
        let base = model.blocks.blocks(filter: filter)
        visible = CommandNavigatorModel.filtered(base, query: query)
        selection = ListNavigation.clampedSelection(
            current: selection, delta: 0, count: visible.count,
        )
        for (segment, pill) in pills { pill.setActive(segment == filter) }
        zeroState.isHidden = !visible.isEmpty
        if visible.isEmpty {
            zeroState.stringValue = CommandNavigatorPresentation.emptyLine(
                filter: filter, hasBlocks: !base.isEmpty,
            )
        }
        drawRows()
        fitList()
        revealSelection()
    }

    private func drawRows() {
        if rows.count != visible.count {
            for row in rows {
                column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = visible.map { _ in
                let row = MacCommandNavigatorRowView(gate: hoverGate, actions: rowActions())
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: column.widthAnchor, constant: -Slate.Metric.space2 * 2,
                ).isActive = true
                return row
            }
        }
        for (index, block) in visible.enumerated() {
            rows[index].show(
                block,
                index: index,
                selected: index == selection,
                starred: model.blocks.isBookmarked(block.index),
                firstSeen: model.blocks.firstSeen(index: block.index),
                query: query,
            )
        }
    }

    /// The five verbs a row can fire, bound ONCE per row rather than re-handed on every draw — a
    /// closure rebuilt per keystroke is the one allocation on that path that is not a string.
    private func rowActions() -> MacCommandNavigatorRowActions {
        MacCommandNavigatorRowActions(
            onHover: { [weak self] index in self?.hover(index) },
            onJump: { [weak self] block in self?.act(block) },
            onReRun: { [weak self] block in self?.reRun(block) },
            onCopyOutput: { [weak self] block in self?.copyOutput(block) },
            onToggleStar: { [weak self] block in self?.toggleStar(block) },
        )
    }

    /// Sizes the results viewport to what the list wants, capped by the token AND by the pane.
    private func fitList() {
        guard let listHeight else { return }
        column.layoutSubtreeIfNeeded()
        let ceiling = Swift.min(CommandNavigatorMetrics.resultsMaxHeight, heightBudget - chromeHeight)
        // A pane too short to hold the chrome at all still gets a scrollable sliver rather than a
        // negative height, which Auto Layout would refuse.
        let wanted = Swift.max(
            Slate.Metric.heightRow, Swift.min(column.fittingSize.height, ceiling),
        )
        guard listHeight.constant != wanted else { return }
        listHeight.constant = wanted
    }

    /// Everything on the card that is NOT the list: the query line, the segment, the foot bar and
    /// the three rules between them.
    private var chromeHeight: CGFloat {
        Slate.Metric.heightInput + Slate.Metric.heightRow * 2 + Slate.Metric.hairline * 3
    }

    /// Scrolls the selected row into view — on a selection CHANGE, and for KEYBOARD navigation only.
    ///
    /// Two guards, and each answers a different way the list could move on its own. The first is the
    /// phone's `.onChange(of: selection)`: a redraw the block model provoked — a command finishing,
    /// a new one starting — is not a selection change, and scrolling on it would yank the list out
    /// from under someone reading it. The second is the hover arbiter, without which the list follows
    /// the mouse: hover selects → the scroll slides a new row under the pointer → hover selects that
    /// one → forever. The arbiter is check-and-clear, so it is consumed only where a change happened.
    private func revealSelection() {
        guard selection != lastRevealed else { return }
        lastRevealed = selection
        guard hoverGate.shouldAutoScrollOnSelectionChange(), rows.indices.contains(selection) else {
            return
        }
        let row = rows[selection]
        column.layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }

    // MARK: The keyboard

    /// The two chords that are not editing commands.
    ///
    /// A command-modified key never reaches the field editor's `doCommandBy:` — AppKit offers it to
    /// the view tree as a key EQUIVALENT first, before the main menu — so ⌘↩ (re-run the selected
    /// command) and ⌘C (copy its output) are read here rather than in ``control(_:textView:doCommandBy:)``.
    /// Both act on the KEYBOARD selection, and they part company on the card: the re-run closes,
    /// because the output it just produced is the thing to look at, and the copy stays open, because
    /// a copy is a side action. The exact-modifier guard is what leaves ⇧⌘C and friends alone; a nil
    /// selection (an empty list) declines both, so ⌘C still reaches the terminal underneath.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return false }
        switch event.specialKey {
        case .carriageReturn,
             .enter:
            if let block = selectedBlock() { reRun(block) }
            return true
        default:
            guard event.charactersIgnoringModifiers == "c", let block = selectedBlock() else {
                return false
            }
            copyOutput(block)
            return true
        }
    }

    func controlTextDidChange(_: Notification) {
        query = field.stringValue
        resetSelection()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.insertNewline(_:)):
            if let block = selectedBlock() { act(block) }
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
        default:
            // Home/End and the page keys are deliberately left alone: in a focused field they belong
            // to the query's caret, and this list is one viewport tall by construction.
            return false
        }
        return true
    }

    // MARK: Acting

    /// The clamp is ``ListNavigation``'s — the rule three overlays had each written for themselves.
    private func move(_ delta: Int) {
        selection = ListNavigation.clampedSelection(
            current: selection, delta: delta, count: visible.count,
        )
        draw()
    }

    private func hover(_ index: Int) {
        guard selection != index else { return }
        hoverGate.noteHoverDrivenSelection()
        selection = index
        draw()
    }

    private func choose(_ segment: BlockNavigatorFilter) {
        guard segment != filter else { return }
        filter = segment
        resetSelection()
    }

    /// A re-filter — by query or by segment — puts the selection back on the first row AND scrolls
    /// there. `lastRevealed` is cleared rather than compared, because the selection may ALREADY be 0
    /// while the viewport is parked halfway down the previous list, and "row 0 is selected" is not
    /// the same fact as "row 0 is on screen".
    private func resetSelection() {
        selection = 0
        lastRevealed = -1
        draw()
    }

    private func selectedBlock() -> CommandBlock? {
        visible.indices.contains(selection) ? visible[selection] : nil
    }

    /// Jumps the active pane's scrollback to `block` — the shared `BlockJump` re-anchor via the
    /// store's active-pane jump, which finds the block's CURRENT position by index and is therefore
    /// robust to a command arriving (or a block evicting) while the card was open — then closes.
    private func act(_ block: CommandBlock) {
        store.jumpToNavigatorBlockInActivePane(index: block.index)
        onClose()
    }

    /// Re-runs `block`'s captured command verbatim in the active pane (the shared, injection-safe
    /// store path). Closes, because the re-run's output is the thing to look at. An empty command is
    /// a store-level no-op.
    private func reRun(_ block: CommandBlock) {
        guard !block.commandText.isEmpty else { return }
        store.reRunCommandInActivePane(block.commandText)
        onClose()
    }

    /// Copies `block`'s captured output (VT-stripped plain text) through the shared request path.
    /// Stays OPEN — a copy is a side action, not a jump — so the pane's own copy receipt underneath
    /// is the confirmation that a possibly huge block landed. The headless core owns no pasteboard,
    /// so the write is the caller's.
    private func copyOutput(_ block: CommandBlock) {
        store.copyBlockOutputInActivePane(index: block.index) { [model] text in
            guard let text, !text.isEmpty else { return }
            ClientPasteboard.write(text)
            model.noteClipboardCopy(text)
        }
    }

    /// Flips `block`'s star through the block model, which persists it via the wired
    /// `onBookmarksChanged`. The redraw comes off the observation arm, not off the click — a glyph
    /// that painted itself here would be a mirror of the set rather than a reading of it.
    private func toggleStar(_ block: CommandBlock) {
        model.blocks.toggleBookmark(index: block.index)
    }
}

// MARK: - One filter segment

/// A pill of the status segment (All | Failed | Bookmarked).
///
/// Selection is a lifted PLATE and a heavier label — never a colour — which is the same house rule
/// the palette's selected row keeps, and the reason this is not a bordered `NSSegmentedControl`: the
/// system control brings its own material and its own accent to a card that has exactly one of each.
@MainActor
final class MacCommandNavigatorFilterPill: NSView {
    var onSelect: () -> Void = {}

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var active = false
    private var hovering = false

    init(_ segment: BlockNavigatorFilter) {
        super.init(frame: .zero)
        // Set HERE rather than relying on the stack that will hold it: the height constraint below is
        // activated before the pill is ever added, and a constraint on a view still translating its
        // autoresizing mask is a conflict AppKit reports at runtime instead of at build time.
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth

        glyph.image = NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil)
        glyph.imageScaling = .scaleNone
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.small, weight: .regular,
        )
        label.stringValue = segment.title
        label.isSelectable = false
        setAccessibilityLabel(segment.title)

        let content = NSStackView(views: [glyph, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space1
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = plateColor().cgColor
            layer?.borderColor = active
                ? Slate.Native.Overlay.hairline.cgColor : NSColor.clear.cgColor
            let ink = active ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary
            label.textColor = ink
            glyph.contentTintColor = ink
            label.font = .systemFont(
                ofSize: Slate.Typeface.footnote, weight: active ? .semibold : .regular,
            )
        }
    }

    /// Rest / hover / selected, one arm per STATE rather than a ternary per property.
    private func plateColor() -> NSColor {
        if active { return Slate.Native.Overlay.plate }
        return hovering ? Slate.Native.State.hover : .clear
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
        onSelect()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - What a row can fire

/// The five verbs one navigator row hands back up.
///
/// A value rather than five parameters on `show(_:…)`, because they are bound ONCE when the row is
/// built while the data is re-cut on every keystroke — and a `show` carrying both would re-hand five
/// closures per row per keystroke.
@MainActor
struct MacCommandNavigatorRowActions {
    let onHover: (Int) -> Void
    let onJump: (CommandBlock) -> Void
    let onReRun: (CommandBlock) -> Void
    let onCopyOutput: (CommandBlock) -> Void
    let onToggleStar: (CommandBlock) -> Void
}

// MARK: - One row

/// One recent command: the exit-status gutter, the command line with the query's hit marked, the
/// meta (duration · age) that gives way to the selected row's two affordances, and the star.
@MainActor
final class MacCommandNavigatorRowView: NSView {
    private let gate: HoverSelectionGate
    private let actions: MacCommandNavigatorRowActions

    private let gutter = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let reRun = MacPlateIconButton(symbolName: "arrow.clockwise")
    private let copyOutput = MacPlateIconButton(symbolName: "doc.on.doc")
    private let star = MacPlateIconButton(symbolName: "star")
    private let content = NSStackView()

    private var block: CommandBlock?
    private var index = 0
    private var selected = false

    init(gate: HoverSelectionGate, actions: MacCommandNavigatorRowActions) {
        self.gate = gate
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth

        gutter.imageScaling = .scaleNone
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.isSelectable = false
        // A command's TAIL is as load-bearing as its head — `just check` and `just check-ios` differ
        // at the end — so the squeeze comes out of the middle.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        meta.font = .monospacedDigitSystemFont(ofSize: Slate.Typeface.small, weight: .regular)
        meta.textColor = Slate.Native.Overlay.tertiary
        meta.isSelectable = false
        meta.maximumNumberOfLines = 1
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)

        reRun.toolTip = CommandNavigatorPresentation.reRunHelp
        reRun.setAccessibilityLabel(CommandNavigatorPresentation.reRunHelp)
        reRun.onClick = { [weak self] in self?.fire(self?.actions.onReRun) }
        copyOutput.toolTip = CommandNavigatorPresentation.copyOutputHelp
        copyOutput.setAccessibilityLabel(CommandNavigatorPresentation.copyOutputHelp)
        copyOutput.onClick = { [weak self] in self?.fire(self?.actions.onCopyOutput) }
        star.toolTip = CommandNavigatorPresentation.bookmarkHelp
        star.setAccessibilityLabel(CommandNavigatorPresentation.bookmarkHelp)
        star.onClick = { [weak self] in self?.fire(self?.actions.onToggleStar) }

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space2
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space3, bottom: 0, right: Slate.Metric.space2,
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [gutter, title] as [NSView] { content.addView(view, in: .leading) }
        for view in [meta, reRun, copyOutput, star] as [NSView] { content.addView(view, in: .trailing) }
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The gutter is a fixed leading column so every command line starts at one x, whatever
            // its own mark turned out to be.
            gutter.widthAnchor.constraint(equalToConstant: Slate.Metric.iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-cuts this row for `block`.
    func show(
        _ block: CommandBlock,
        index: Int,
        selected: Bool,
        starred: Bool,
        firstSeen: Date?,
        query: String,
    ) {
        self.block = block
        self.index = index
        self.selected = selected
        showGutter(block)
        title.attributedStringValue = Self.marked(block.commandText, query: query, selected: selected)
        setAccessibilityLabel(block.commandText)
        // The two affordances live on the SELECTED (hover or keyboard) row only, so a resting list
        // stays clean; the meta collapses under them when they are up.
        let line = Self.metaLine(block, firstSeen: firstSeen)
        meta.stringValue = line
        meta.isHidden = selected || line.isEmpty
        reRun.isHidden = !selected
        copyOutput.isHidden = !selected
        reRun.enabled = !block.commandText.isEmpty
        // Compared before assigning: `symbolName` repaints from its `didSet`, which fires on an equal
        // value too, and this runs for every row on every keystroke.
        let glyph = starred ? "star.fill" : "star"
        if star.symbolName != glyph { star.symbolName = glyph }
        star.active = starred
        needsDisplay = true
    }

    /// The status gutter — green ✓ / red ✗ / a grey dot — through the pure
    /// ``OutlinePresentation/gutter(for:)`` classification, so the navigator and the Outline never
    /// disagree about what counts as success. The colour is the only theme-coupled part, and it is
    /// ``Slate/StatusInk`` rather than the on-glass pair because this card is PAPER: the ink follows
    /// the plate it stands on, not the island it floats over.
    private func showGutter(_ block: CommandBlock) {
        switch OutlinePresentation.gutter(for: block) {
        case .succeeded:
            gutter.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            gutter.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .bold,
            )
            gutter.contentTintColor = Slate.Native.StatusInk.ok
        case .failed:
            gutter.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            gutter.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .bold,
            )
            gutter.contentTintColor = Slate.Native.StatusInk.err
        case .running:
            gutter.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            gutter.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .regular,
            )
            gutter.contentTintColor = Slate.Native.Overlay.tertiary
        }
    }

    /// `1.4s · 4m ago` — the duration the block reports and the age the Outline words, joined by the
    /// app's one separator. Either half may be missing; both missing is an empty line.
    private static func metaLine(_ block: CommandBlock, firstSeen: Date?) -> String {
        var parts: [String] = []
        if let duration = block.durationLabel { parts.append(duration) }
        if let firstSeen {
            parts.append(OutlinePresentation.relativeTime(from: firstSeen, now: Date()))
        }
        return parts.joined(separator: " · ")
    }

    /// The command line with the query's matched runs marked by CONTRAST — the hit keeps the reading
    /// ink and goes a weight up while the letters around it step back. WHERE the cuts fall is
    /// ``FuzzyMatcher/runs(of:ranges:)``'s; the ink is this renderer's, exactly as on the palette.
    ///
    /// Monospaced, because a command line is terminal text and the Mac's other surface that shows
    /// terminal text (``MacGlobalSearchRowView``) sets it in the same face. A still-forming block has
    /// no command text yet and shows an em-dash; no real query can match it, so it appears only in
    /// the zero-query list.
    private static func marked(_ text: String, query: String, selected: Bool) -> NSAttributedString {
        let line = text.isEmpty ? "—" : text
        let base = NSFont.monospacedSystemFont(
            ofSize: Slate.Typeface.body, weight: selected ? .medium : .regular,
        )
        let hit = NSFont.monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranges = trimmed.isEmpty ? [] : FuzzyMatcher.score(trimmed, line)?.ranges ?? []
        let runs = FuzzyMatcher.runs(of: line, ranges: ranges)
        guard runs.count > 1 else {
            return .slateNerdAware(line, font: base, color: Slate.Native.Overlay.primary)
        }
        let spliced = NSMutableAttributedString()
        for run in runs {
            spliced.append(.slateNerdAware(
                run.text,
                font: run.matched ? hit : base,
                color: run.matched
                    ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary,
            ))
        }
        return spliced
    }

    /// One of the row's own buttons, against the block it is currently showing.
    private func fire(_ action: ((CommandBlock) -> Void)?) {
        guard let block, let action else { return }
        action(block)
    }

    // MARK: The plate

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected
                ? Slate.Native.Overlay.plate.cgColor : NSColor.clear.cgColor
            layer?.borderColor = selected
                ? Slate.Native.Overlay.hairline.cgColor : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    /// Hover moves the keyboard's selection onto this row — but only on genuine pointer MOVEMENT. A
    /// keyboard scroll slides a new row under a parked pointer and AppKit re-fires the entry for it;
    /// admitting that would yank the selection back to wherever the mouse was left.
    override func mouseEntered(with _: NSEvent) {
        guard gate.admitHover(at: NSEvent.mouseLocation), !selected else { return }
        actions.onHover(index)
    }

    /// The row IS the click target — a target laid OVER a row is topmost for the pointer and eats the
    /// hover underneath it. The three plates are subviews, so they take their own clicks first.
    override func mouseDown(with _: NSEvent) {
        fire(actions.onJump)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
