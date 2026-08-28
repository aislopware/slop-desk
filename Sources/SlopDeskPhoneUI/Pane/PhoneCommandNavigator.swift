// PhoneCommandNavigator — the Command Navigator card (⌃⌘O) over the ACTIVE pane, in UIKit.
//
// ⌃⌘O was a LIVE DEAD CHORD on this platform until this file, exactly as it was on the Mac before
// `MacCommandNavigator.swift`: `view.commandNavigator` (`binding_rows.rs:131`) routes through
// ``WorkspaceBindingRegistry`` → ``WorkspaceStore/requestBlockNavigatorInActivePane()`` → the active
// pane model's `onRequestBlockNavigator`, which ``TerminalPaneWiring`` binds to a TOGGLE on
// ``CommandNavigatorChrome/isVisible``. The phone's SwiftUI card was deleted with the rest of that
// half (docs/62 §2.2) and the flag went unread, so the chord took ⌃⌘O away from the PTY to flip a
// `Bool` nobody drew. ``TerminalLeafView``'s own ⚠️ recorded the hole; this closes it.
//
// IT IS THE MAC CARD'S TWIN, not a second design. Every decision was already shared and is CALLED:
//   • the list — ``TerminalBlockModel/blocks(filter:)`` on the pane's LIVE model (no snapshot, so a
//     command that finishes while the card is up flips its own gutter in place);
//   • the ranking — ``CommandNavigatorModel/filtered(_:query:)``, one line over `search_rank`;
//   • the clamp — ``ListNavigation/clampedSelection(current:delta:count:)``;
//   • the jump — ``WorkspaceStore/jumpToNavigatorBlockInActivePane(index:)``;
//   • the two row verbs — ``WorkspaceStore/reRunCommandInActivePane(_:)`` and
//     ``WorkspaceStore/copyBlockOutputInActivePane(index:onResult:)``;
//   • the stars — ``TerminalBlockModel``'s bookmarks API, persisted through `onBookmarksChanged`;
//   • the pointer arbiter — ``HoverSelectionGate``;
//   • the words and the two measurements — ``CommandNavigatorPresentation`` /
//     ``CommandNavigatorMetrics``.
// Nothing below re-derives a ranking, a clamp, a zero-state sentence or a jump.
//
// ## SEVEN PLACES THIS DIVERGES FROM THE MAC TWIN, each because UIKit answers differently
//
//  1. NO POINTER SHIELD, so there is no ``SlopDeskMacUI/MacPaneCardShield`` counterpart and no count
//     to balance. That type exists because an `NSTrackingArea` is RECT-based and keeps firing under
//     whatever is composited above it — a terminal under a card goes on feeding cursor positions to a
//     mouse-reporting TUI. iOS has no tracking areas at all: a pointer reaches a view through a
//     `UIHoverGestureRecognizer`, which is attached TO a view and is therefore already occluded by
//     this card, and touches stop at the topmost hit-tested view by construction. The hazard does not
//     exist here, so neither does its countermeasure.
//  2. NO DEFERRED FOCUS HOP. The Mac hands the query field first responder one runloop late because a
//     field cannot take it before its window is key. ``SlateSearchBarView`` grabs the responder in its
//     own `didMoveToWindow` and the component's header says why re-adding a hop would be cargo cult,
//     so this card says nothing about focus at all.
//  3. THE KEYBOARD IS `UIKeyCommand`s, not `performKeyEquivalent` + `doCommandBy:`. UIKit has neither
//     door; it collects `keyCommands` from the whole responder chain, and this card is behind the
//     query field on that chain — which is what keeps the field's own editing keys working.
//  4. A HELD ARROW DOES NOT REPEAT, and that is a hole rather than a decision — see ``keyCommands``.
//  5. THE SELECTION PLATE IS ``SlateSelectionPlateSurface``'s, not a hand-cut layer fill. The phone's
//     design floor already made that decision for every list row in the app; the Mac predates it.
//  6. THE STAR NEVER SWAPS ITS GLYPH. ``SlatePlateIconButton`` takes its symbol at `init` and says a
//     latch is INK AND WEIGHT rather than a second glyph, so a starred row is `active` on one `star`
//     rather than `star` → `star.fill`. That is the phone floor's rule, and it is the same reason the
//     Mac's star is not amber.
//  7. THE MATCHED RUN IS CONTRAST, as it is on the Mac. The Mac header's parenthetical says the phone
//     "tints the run with the accent" — it did once, and the deleted card had already moved off it.
//     ``FuzzyMatcher/runs(of:ranges:)`` cuts the runs; this file inks them in weight.
//
// IT IS PANE-LOCAL for the reason the Mac's is: the navigator floats over ONE pane's terminal, so its
// scrim is the pane's rect and its lifetime is the leaf's ``CommandNavigatorChrome`` rather than the
// overlay coordinator's. It is not a member of the summoned-card family that
// ``PhoneOverlayCardHost`` presents, and a card over one pane must not deafen the chrome columns.

#if os(iOS)
import Foundation
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // ListNavigation — the clamp all three list overlays share
import UIKit

// MARK: - The scrim, and the card standing on it

/// The navigator as the leaf mounts it: a pane-local dismiss floor with the paper card centred on it.
///
/// It fills the pane's surface area, so the scrim is the pane's own rect and not the window's.
@MainActor
final class PhoneCommandNavigatorView: UIView {
    /// Clears the pane chrome's `isVisible`. Fired by Esc, by a tap beside the card, and by a row that
    /// acted.
    private let onClose: () -> Void

    /// The DISMISS FLOOR. A `UIControl` rather than a `hitTest` on this view, because the component
    /// already exists and already carries the "clear is not transparent" rule its header states: the
    /// floor is drawn clear and left fully opaque, or it silently stops dismissing.
    private let floor: SlateClickTargetView
    private let card = UIView()
    private let content: PhoneCommandNavigatorCardView

    /// Whether this card has been dismissed and is only finishing its fade. See ``retire()``.
    private var retired = false

    init(model: TerminalViewModel, store: WorkspaceStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        floor = SlateClickTargetView(action: onClose)
        content = PhoneCommandNavigatorCardView(model: model, store: store, onClose: onClose)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The veil. A VIEW-level fill holds the dynamic colour itself, so unlike the Mac's `updateLayer`
        // + appearance override there is nothing here to re-ink on a theme flip.
        backgroundColor = Slate.Native.State.shadow

        card.translatesAutoresizingMaskIntoConstraints = false
        SlatePaperCardSurface.apply(to: card)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        // The floor goes in FIRST so the card is above it and takes its own taps.
        addSubview(floor)
        addSubview(card)

        // The width is the card's own; the HEIGHT is intrinsic, so a two-row list gets a two-row card
        // rather than a full-height one padded out with nothing.
        let width = card.widthAnchor.constraint(
            equalToConstant: CommandNavigatorMetrics.panelWidth,
        )
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            floor.leadingAnchor.constraint(equalTo: leadingAnchor),
            floor.trailingAnchor.constraint(equalTo: trailingAnchor),
            floor.topAnchor.constraint(equalTo: topAnchor),
            floor.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            // ⚠️ THE ONE CONSTRAINT THE MAC DOES NOT NEED. A Mac pane is never narrower than the card
            // in practice; a phone pane in a vertical split on a compact device is, and a fixed width
            // there would hang the card's affordances off both sides of the pane it belongs to. The
            // fixed width is `defaultHigh` and this cap is required, so the card shrinks instead.
            card.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -2 * Slate.Metric.space4,
            ),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Arriving and leaving

    /// Fades the card in, under ``Slate/Motion/reveal``.
    ///
    /// Opacity ONLY, with no travel: the chips slide because they arrive at an edge of a pane that is
    /// already being read, while this lands in the middle of it — a card that flew in would drag the
    /// eye across the terminal it is about to cover.
    func reveal() {
        alpha = 0
        animate { self.alpha = 1 }
    }

    /// Fades the card out and removes it when it settles.
    ///
    /// `retired` is set FIRST and the interaction flag goes with it, because `alpha` is a drawing
    /// property: a card at alpha 0.2 still swallows the touch meant for the terminal returning
    /// underneath it. UIKit spells the Mac's `hitTest` gate as `isUserInteractionEnabled`, which drops
    /// this view AND its whole subtree out of the hit-test walk in one write.
    ///
    /// The leaf forgets the card and calls ``teardown()`` before this, so a second ⌃⌘O during the fade
    /// builds a fresh one rather than finding this one on its way out.
    func retire() {
        guard !retired else { return }
        retired = true
        isUserInteractionEnabled = false
        animate({ self.alpha = 0 }, thenRemoving: self)
    }

    /// Supersedes the card's observation arm. Called by the leaf on BOTH close paths — the animated
    /// ``retire()`` and the hard drop — because a card that is still fading is still armed, and an arm
    /// cannot be cancelled (docs/62 §3.1).
    func teardown() {
        content.teardown()
    }

    /// The reveal curve around one mutation, optionally retiring a view when it settles.
    ///
    /// `UIViewPropertyAnimator` rather than `UIView.animate(withDuration:)`, because the rung is a
    /// CUBIC BEZIER and the convenience API takes only a `UIView.AnimationOptions` easing name — the
    /// same reason ``TerminalLeafView``'s chip reveal spells it this way.
    private func animate(_ body: @escaping () -> Void, thenRemoving retiring: UIView? = nil) {
        let curve = Slate.Motion.reveal
        let animator = UIViewPropertyAnimator(
            duration: curve.duration,
            controlPoint1: CGPoint(x: curve.x1, y: curve.y1),
            controlPoint2: CGPoint(x: curve.x2, y: curve.y2),
            animations: body,
        )
        animator.addCompletion { _ in retiring?.removeFromSuperview() }
        animator.startAnimation()
    }

    /// The results ceiling is the pane's to cap, not only the token's: a split pane can be shorter than
    /// ``CommandNavigatorMetrics/resultsMaxHeight``, and a card taller than the surface it floats over
    /// would run out past the island's edge. Pushed rather than read so the card owns one number and
    /// the container owns where it came from.
    ///
    /// The shadow path is the other half of ``SlatePaperCardSurface``'s contract — without it the cast
    /// is a per-frame rasterisation of the whole layer tree under the card.
    override func layoutSubviews() {
        super.layoutSubviews()
        SlatePaperCardSurface.layoutShadow(of: card)
        content.heightBudget = bounds.height - 2 * Slate.Metric.space4
    }

    /// Esc closes. It is declared on the FLOOR rather than on the card for the reason the Mac declares
    /// `cancelOperation` there: the floor is the object that owns the dismissal, and the responder
    /// chain is what gives it reach from the focused query field.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.slateCancel(action: #selector(closeCard))]
    }

    @objc
    private func closeCard() { onClose() }
}

// MARK: - The card's content

/// The card itself: a pre-focused query line, the status segment, the ranked list, and the foot bar.
@MainActor
final class PhoneCommandNavigatorCardView: UIView {
    /// The pane's live terminal model — its pure block store is this card's data source and its
    /// bookmarks API backs the star. This is the pane the card floats over (the active one).
    private let model: TerminalViewModel
    /// The live store — performs the jump, the re-run and the output copy through the shared paths.
    private let store: WorkspaceStore
    private let onClose: () -> Void

    private let search = SlateSearchBarView(
        prompt: CommandNavigatorPresentation.searchPlaceholder,
    )
    private let queryRule = SlateCardSeparatorView()
    private let filterTray = UIStackView()
    private let filterRule = SlateCardSeparatorView()
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let footerRule = SlateCardSeparatorView()
    private let footer = UIStackView()

    private var pills: [BlockNavigatorFilter: PhoneCommandNavigatorFilterPill] = [:]
    /// The row views currently in the column, in draw order — kept so a selection step moves the plate
    /// without rebuilding a list that did not change.
    private var rows: [PhoneCommandNavigatorRowView] = []
    /// The rows as last drawn, so the keyboard verbs act on what the eye is looking at.
    private var visible: [CommandBlock] = []

    /// The zero-state line, and the sentence it was built with.
    ///
    /// ⚠️ REBUILT RATHER THAN RELABELLED, because ``SlateNoResultsLineView``'s message is an `init`
    /// parameter by design (its header says why). The sentence changes only when the SEGMENT or the
    /// "has blocks" answer changes — never per keystroke — so the rebuild is not on a hot path, and
    /// the alternative is a second zero-state voice minted in this file.
    private var zeroLine: SlateNoResultsLineView?
    private var zeroMessage: String?

    private var query = ""
    private var filter = BlockNavigatorFilter.all
    private var selection = 0
    /// The selection the viewport was last scrolled for. `-1` is "never", which no index can be, so the
    /// first draw does not scroll a list that has not moved.
    private var lastRevealed = -1
    /// Hover→selection arbiter: a hover-driven selection must not auto-scroll, and a list scrolling
    /// under a PARKED pointer must not steal the selection. One per presentation, shared by the rows.
    ///
    /// It is mounted UNCONDITIONALLY even though an iPhone has no pointer: the rows drive it from a
    /// `UIHoverGestureRecognizer`, which only ever fires where a pointer exists (iPadOS with a
    /// trackpad), so a touch-only device pays one unused object rather than a device check.
    private let hoverGate = HoverSelectionGate()

    private var listHeight: NSLayoutConstraint?

    /// Supersedes the observation arm — see ``render()``.
    private var generation = 0

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
        translatesAutoresizingMaskIntoConstraints = false

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
        // No plate and no bezel: the CARD is the surface, and a second plate drawn inside it would read
        // as an input sunk into paper rather than as the card's own first line. `SlateSearchBarView` is
        // exactly that shape already — a magnifier, a bare field, the input-strip height — and it also
        // owns the opening focus grab, which is why divergence 2 has nothing to say here.
        search.onTextChange = { [weak self] text in
            guard let self else { return }
            query = text
            resetSelection()
        }
        search.onSubmit = { [weak self] in
            guard let self, let block = selectedBlock() else { return }
            act(block)
        }
        addSubview(search)
        addSubview(queryRule)
    }

    private func buildFilters() {
        // A TRANSPARENT tray: each pill delineates itself, so the container only spaces them.
        filterTray.axis = .horizontal
        filterTray.alignment = .center
        filterTray.spacing = Slate.Metric.space1
        filterTray.translatesAutoresizingMaskIntoConstraints = false
        for segment in BlockNavigatorFilter.allCases {
            let pill = PhoneCommandNavigatorFilterPill(segment)
            pill.onSelect = { [weak self] in self?.choose(segment) }
            pills[segment] = pill
            filterTray.addArrangedSubview(pill)
        }
        addSubview(filterTray)
        addSubview(filterRule)
    }

    private func buildResults() {
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        // The rows must not touch the card's own edge — a row clipped flush against the rim reads as a
        // rendering fault rather than as "there is more below".
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space2, leading: Slate.Metric.space2,
            bottom: Slate.Metric.space2, trailing: Slate.Metric.space2,
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        // The list is one viewport tall by construction and the card is a modal surface; a rubber-band
        // bounce past a three-row list reads as the card itself coming loose.
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            // The UIKit spelling of the Mac's clip-view width pin: the CONTENT guide fixes where the
            // column sits in the scrollable area, and the FRAME guide's width is what makes the rows
            // lay out at the card's width so the scrolling is vertical only. A column pinned to the
            // content guide alone is free in both axes and scrolls sideways instead.
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    private func buildFooter() {
        addSubview(footerRule)
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = Slate.Metric.space3
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addArrangedSubview(Self.hint(CommandNavigatorPresentation.navigateHint))
        // The gap that pushes the last two hints to the trailing edge. `NSStackView` says this with a
        // gravity; `UIStackView` has none, so the spacer IS the gravity — one empty view, hugging at
        // the floor so it takes every point the hints do not.
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        for value in [CommandNavigatorPresentation.jumpHint, CommandNavigatorPresentation.closeHint] {
            footer.addArrangedSubview(Self.hint(value))
        }
        addSubview(footer)
    }

    /// One foot-bar hint: what the key does, then the key itself as a ``SlateKeycapView`` — the app's
    /// one cap, in the system face, so a chord in a hint and a chord in the cheat sheet read alike.
    private static func hint(_ value: CommandNavigatorHint) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = value.label
        label.font = .systemFont(ofSize: Slate.Typeface.small)
        label.textColor = Slate.Native.Overlay.tertiary
        let pair = UIStackView(arrangedSubviews: [label, SlateKeycapView(label: value.glyph)])
        pair.translatesAutoresizingMaskIntoConstraints = false
        pair.axis = .horizontal
        pair.alignment = .center
        pair.spacing = Slate.Metric.space1
        return pair
    }

    private func placeParts() {
        let list = scroll.heightAnchor.constraint(
            equalToConstant: CommandNavigatorMetrics.resultsMaxHeight,
        )
        listHeight = list
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: leadingAnchor),
            search.trailingAnchor.constraint(equalTo: trailingAnchor),
            search.topAnchor.constraint(equalTo: topAnchor),

            queryRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            queryRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            queryRule.topAnchor.constraint(equalTo: search.bottomAnchor),

            filterTray.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Slate.Metric.space3,
            ),
            filterTray.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Slate.Metric.space3,
            ),
            filterTray.topAnchor.constraint(equalTo: queryRule.bottomAnchor),
            filterTray.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),

            filterRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterRule.topAnchor.constraint(equalTo: filterTray.bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterRule.bottomAnchor),
            list,

            footerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerRule.topAnchor.constraint(equalTo: scroll.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            footer.topAnchor.constraint(equalTo: footerRule.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: The live read

    /// Draws the current state and re-arms itself on everything it read.
    ///
    /// The card reads the LIVE block model rather than a snapshot, which is the whole reason this is an
    /// observation arm and not a one-shot draw: a command that finishes while the navigator is open
    /// flips its own gutter, and a command that STARTS while it is open appears.
    ///
    /// THE GENERATION GUARD IS THIS PLATFORM'S RULE (docs/62 §3.1) and the Mac's twin does without it.
    /// It is not decoration: a card only fading out is still armed, and `onChange` fires INSIDE the
    /// mutation — so the callback hops the main queue and then checks that the arm it came from is
    /// still the current one. ``teardown()`` bumps the counter and is what makes a dismissed card stop.
    private func render() {
        generation &+= 1
        let generation = generation
        withObservationTracking {
            draw()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.render()
                }
            }
        }
    }

    /// Drops the arm. Idempotent, and the only thing this card owns that a `deinit` could not be relied
    /// on to reach in time.
    func teardown() {
        generation &+= 1
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
        drawRows()
        drawZeroState(hasBlocks: !base.isEmpty)
        fitList()
        revealSelection()
    }

    private func drawRows() {
        if rows.count != visible.count {
            for row in rows { row.removeFromSuperview() }
            let actions = rowActions()
            rows = visible.map { _ in
                let row = PhoneCommandNavigatorRowView(gate: hoverGate, actions: actions)
                column.addArrangedSubview(row)
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

    /// The one zero-state voice for a list surface: a single centred line, text-only, no glyph. The
    /// SENTENCE is ``CommandNavigatorPresentation/emptyLine(filter:hasBlocks:)``'s — it answers "the
    /// query matched nothing" and "this segment is empty" differently, and neither is re-worded here.
    private func drawZeroState(hasBlocks: Bool) {
        guard visible.isEmpty else {
            guard let line = zeroLine else { return }
            zeroLine = nil
            zeroMessage = nil
            line.removeFromSuperview()
            return
        }
        let message = CommandNavigatorPresentation.emptyLine(filter: filter, hasBlocks: hasBlocks)
        guard message != zeroMessage else { return }
        zeroMessage = message
        zeroLine?.removeFromSuperview()
        let line = SlateNoResultsLineView(message: message, ink: Slate.Native.Overlay.tertiary)
        zeroLine = line
        column.addArrangedSubview(line)
    }

    /// The five verbs a row can fire, bound ONCE per row rather than re-handed on every draw — a
    /// closure rebuilt per keystroke is the one allocation on that path that is not a string.
    private func rowActions() -> PhoneCommandNavigatorRowActions {
        PhoneCommandNavigatorRowActions(
            onHover: { [weak self] index in self?.hover(index) },
            onJump: { [weak self] block in self?.act(block) },
            onReRun: { [weak self] block in self?.reRun(block) },
            onCopyOutput: { [weak self] block in self?.copyOutput(block) },
            onToggleStar: { [weak self] block in self?.toggleStar(block) },
        )
    }

    /// Sizes the results viewport to what the list wants, capped by the token AND by the pane.
    ///
    /// ⚠️ MEASURED, NEVER LAID OUT. The Mac can call `layoutSubtreeIfNeeded()` here; this method is
    /// reachable from ``heightBudget``'s `didSet`, which the container writes from ITS `layoutSubviews`
    /// — and forcing a layout pass from inside one is the reentrancy docs/62 hazard 7 is about. Every
    /// row carries a fixed height constraint, so a fitting-size measurement answers exactly.
    private func fitList() {
        guard let listHeight else { return }
        let width = bounds.width > 0 ? bounds.width : CommandNavigatorMetrics.panelWidth
        let wants = column.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        ).height
        let ceiling = CGFloat.minimum(
            CommandNavigatorMetrics.resultsMaxHeight, heightBudget - chromeHeight,
        )
        // A pane too short to hold the chrome at all still gets a scrollable sliver rather than a
        // negative height, which Auto Layout would refuse.
        let wanted = CGFloat.maximum(Slate.Metric.heightRow, CGFloat.minimum(wants, ceiling))
        guard listHeight.constant != wanted else { return }
        listHeight.constant = wanted
    }

    /// Everything on the card that is NOT the list: the query line, the segment, the foot bar and the
    /// three rules between them.
    private var chromeHeight: CGFloat {
        Slate.Metric.heightInput + Slate.Metric.heightRow * 2 + Slate.Metric.hairline * 3
    }

    /// Scrolls the selected row into view — on a selection CHANGE, and for KEYBOARD navigation only.
    ///
    /// Two guards, and each answers a different way the list could move on its own. The first: a redraw
    /// the block model provoked — a command finishing, a new one starting — is not a selection change,
    /// and scrolling on it would yank the list out from under someone reading it. The second is the
    /// hover arbiter, without which the list follows the pointer: hover selects → the scroll slides a
    /// new row under the pointer → hover selects that one → forever. The arbiter is check-and-clear, so
    /// it is consumed only where a change happened.
    private func revealSelection() {
        guard selection != lastRevealed else { return }
        lastRevealed = selection
        guard hoverGate.shouldAutoScrollOnSelectionChange(), rows.indices.contains(selection) else {
            return
        }
        let row = rows[selection]
        scroll.layoutIfNeeded()
        scroll.scrollRectToVisible(row.frame, animated: false)
    }

    // MARK: The keyboard

    /// The four chords the card answers, as `UIKeyCommand`s on the responder chain.
    ///
    /// ⚠️ A HELD ARROW DOES NOT REPEAT, and that is a HOLE rather than a choice. The deleted card ran
    /// held arrows through `OverlayKeyRepeat`, which was typed on `KeyEquivalent` and `KeyPress.Phases`
    /// — neither of which UIKit has. docs/62 §7 item 1 does not port it: it MERGES into
    /// `rust/slopdesk-workspace::key_repeat`, so the overlays become a second consumer of the same
    /// hardware latch the terminal already drives, off `pressesBegan`/`pressesEnded`. That stage has
    /// not landed, and inventing a private repeat clock here is exactly the parallel policy the merge
    /// exists to end. Until it does, each press steps one row.
    ///
    /// The ARROWS take priority: the query field is the first responder and would otherwise spend them
    /// on its own caret. ⌘↩ and ⌘C do NOT, which is what leaves the field's own ⌘C over a text
    /// selection to the chain — those two are also gated by ``canPerformAction(_:withSender:)`` so an
    /// empty list declines them and ⌘C reaches the terminal underneath, which is the Mac's rule.
    override var keyCommands: [UIKeyCommand]? {
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(stepUp))
        let down = UIKeyCommand(
            input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(stepDown),
        )
        up.wantsPriorityOverSystemBehavior = true
        down.wantsPriorityOverSystemBehavior = true
        return [
            up,
            down,
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(reRunChord)),
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copyOutputChord)),
        ]
    }

    /// A nil selection (an empty list) declines both ⌘-chords, so they fall through the chain.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(reRunChord),
             #selector(copyOutputChord):
            selectedBlock() != nil
        default:
            super.canPerformAction(action, withSender: sender)
        }
    }

    @objc
    private func stepUp() { move(-1) }

    @objc
    private func stepDown() { move(1) }

    @objc
    private func reRunChord() {
        guard let block = selectedBlock() else { return }
        reRun(block)
    }

    @objc
    private func copyOutputChord() {
        guard let block = selectedBlock() else { return }
        copyOutput(block)
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
    /// while the viewport is parked halfway down the previous list, and "row 0 is selected" is not the
    /// same fact as "row 0 is on screen".
    private func resetSelection() {
        selection = 0
        lastRevealed = -1
        draw()
    }

    private func selectedBlock() -> CommandBlock? {
        visible.indices.contains(selection) ? visible[selection] : nil
    }

    /// Jumps the active pane's scrollback to `block` — the shared `BlockJump` re-anchor via the store's
    /// active-pane jump, which finds the block's CURRENT position by index and is therefore robust to a
    /// command arriving (or a block evicting) while the card was open — then closes.
    private func act(_ block: CommandBlock) {
        store.jumpToNavigatorBlockInActivePane(index: block.index)
        onClose()
    }

    /// Re-runs `block`'s captured command verbatim in the active pane (the shared, injection-safe store
    /// path). Closes, because the re-run's output is the thing to look at. An empty command is a
    /// store-level no-op.
    private func reRun(_ block: CommandBlock) {
        guard !block.commandText.isEmpty else { return }
        store.reRunCommandInActivePane(block.commandText)
        onClose()
    }

    /// Copies `block`'s captured output (VT-stripped plain text) through the shared request path. Stays
    /// OPEN — a copy is a side action, not a jump — so the pane's own copy receipt underneath is the
    /// confirmation that a possibly huge block landed. The headless core owns no pasteboard, so the
    /// write is the caller's.
    private func copyOutput(_ block: CommandBlock) {
        store.copyBlockOutputInActivePane(index: block.index) { [model] text in
            guard let text, !text.isEmpty else { return }
            ClientPasteboard.write(text)
            model.noteClipboardCopy(text)
        }
    }

    /// Flips `block`'s star through the block model, which persists it via the wired
    /// `onBookmarksChanged`. The redraw comes off the observation arm, not off the tap — a glyph that
    /// painted itself here would be a mirror of the set rather than a reading of it.
    private func toggleStar(_ block: CommandBlock) {
        model.blocks.toggleBookmark(index: block.index)
    }
}

// MARK: - One filter segment

/// A pill of the status segment (All | Failed | Bookmarked).
///
/// Selection is a lifted PLATE and a heavier label — never a colour — which is the same house rule the
/// palette's selected row keeps, and the reason this is not a `UISegmentedControl`: the system control
/// brings its own material and its own accent to a card that has exactly one of each.
@MainActor
final class PhoneCommandNavigatorFilterPill: UIControl {
    var onSelect: () -> Void = {}

    private let glyph = UIImageView()
    private let label = UILabel()
    private var active = false
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            reink()
        }
    }

    init(_ segment: BlockNavigatorFilter) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.cardBorderWidth

        // The segment's own glyph name, off ``BlockNavigatorFilter/symbol`` — the mapping is the
        // model's and is not re-typed here, which is also why this one takes a NAME where the rest of
        // the file takes an `SFSymbol`.
        glyph.image = UIImage(systemName: segment.symbol)
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Slate.Typeface.small, weight: .regular,
        )
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        label.text = segment.title
        label.isUserInteractionEnabled = false
        accessibilityLabel = segment.title
        accessibilityTraits = .button

        let content = UIStackView(arrangedSubviews: [glyph, label])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Slate.Metric.space1
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        reink()
        // Only the two `CGColor`s below are flat; the label's ink is a view-level dynamic colour and
        // follows the appearance on its own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: Self, _: UITraitCollection) in
            pill.reink()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        reink()
    }

    private func reink() {
        // Rest / hover / selected, one arm per STATE rather than a ternary per property.
        let plate: UIColor =
            if active {
                Slate.Native.Overlay.plate
            } else if hovering {
                Slate.Native.State.hover
            } else {
                .clear
            }
        backgroundColor = plate
        layer.borderColor = active
            ? Slate.Native.Overlay.hairline.resolvedColor(with: traitCollection).cgColor
            : UIColor.clear.cgColor
        let ink = active ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary
        label.textColor = ink
        glyph.tintColor = ink
        label.font = .systemFont(
            ofSize: Slate.Typeface.footnote, weight: active ? .semibold : .regular,
        )
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began,
             .changed: hovering = true
        default: hovering = false
        }
    }

    @objc
    private func fire() { onSelect() }
}

// MARK: - What a row can fire

/// The five verbs one navigator row hands back up.
///
/// A value rather than five parameters on `show(_:…)`, because they are bound ONCE when the row is
/// built while the data is re-cut on every keystroke — and a `show` carrying both would re-hand five
/// closures per row per keystroke.
@MainActor
struct PhoneCommandNavigatorRowActions {
    let onHover: (Int) -> Void
    let onJump: (CommandBlock) -> Void
    let onReRun: (CommandBlock) -> Void
    let onCopyOutput: (CommandBlock) -> Void
    let onToggleStar: (CommandBlock) -> Void
}

// MARK: - One row

/// One recent command: the exit-status gutter, the command line with the query's hit marked, the meta
/// (duration · age) that gives way to the selected row's two affordances, and the star.
///
/// ⚠️ A `UIControl` OF ITS OWN, not a ``SlateRowButton``. The design floor's rule is that the row's own
/// CONTAINER is the control — a transparent target laid on top is what `hitTest(_:)` returns, so it
/// eats the row's `UIHoverGestureRecognizer` along with its taps — and this type IS that container. It
/// is not the shared class because that one is `final` and stateless by design, while a navigator row
/// carries a block, an index and a selection flag between draws, and mounts three plates that must
/// take their own taps first.
@MainActor
final class PhoneCommandNavigatorRowView: UIControl {
    private let gate: HoverSelectionGate
    private let actions: PhoneCommandNavigatorRowActions

    private let gutter = UIImageView()
    private let title = UILabel()
    private let meta = UILabel()
    private let reRun: SlatePlateVerbButton
    private let copyOutput: SlatePlateVerbButton
    private let star: SlatePlateIconButton

    private var block: CommandBlock?
    private var index = 0

    init(gate: HoverSelectionGate, actions: PhoneCommandNavigatorRowActions) {
        self.gate = gate
        self.actions = actions
        // ⚠️ THE THREE PLATES CARRY NO CLOSURE, and that is the ONE thing here that is not the Mac's
        // shape. Both plate controls take their verb as a `let` at `init`, which is BEFORE `super.init`
        // — so a closure bound here could not name `self` at all, and a captured box would only be a
        // longer way of writing the target-action UIKit already has. Both are `UIControl`s, so a second
        // `.touchUpInside` target is added below: the plate keeps its own press ladder and its
        // acknowledgement, and the row keeps a verb that fires against the block it is CURRENTLY
        // showing rather than one captured when it was built.
        reRun = SlatePlateVerbButton(
            symbol: .arrowClockwise, help: CommandNavigatorPresentation.reRunHelp,
            tint: Slate.Native.Overlay.secondary,
        )
        copyOutput = SlatePlateVerbButton(
            symbol: .docOnDoc, help: CommandNavigatorPresentation.copyOutputHelp,
            tint: Slate.Native.Overlay.secondary,
        )
        // ⚠️ ONE GLYPH, LATCHED — never `star` → `star.fill`. ``SlatePlateIconButton`` takes its symbol
        // at `init` and states the house rule its `active` implements: a latch is INK AND WEIGHT, not a
        // hue and not a second glyph. The Mac swaps the glyph because its plate has no latch.
        star = SlatePlateIconButton(symbol: .star)
        super.init(frame: .zero)
        reRun.addTarget(self, action: #selector(reRunTapped), for: .touchUpInside)
        copyOutput.addTarget(self, action: #selector(copyOutputTapped), for: .touchUpInside)
        star.addTarget(self, action: #selector(starTapped), for: .touchUpInside)

        translatesAutoresizingMaskIntoConstraints = false
        // The row's plate is the design floor's, not a hand-cut layer fill: `install` owns the corner
        // and the trait registration once, `apply` moves the fill and the border width per draw.
        SlateSelectionPlateSurface.install(on: self)

        gutter.contentMode = .center
        gutter.isUserInteractionEnabled = false
        title.numberOfLines = 1
        // A command's TAIL is as load-bearing as its head — `just check` and `just check-ios` differ at
        // the end — so the squeeze comes out of the middle.
        title.lineBreakMode = .byTruncatingMiddle
        title.isUserInteractionEnabled = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        meta.font = .monospacedDigitSystemFont(ofSize: Slate.Typeface.small, weight: .regular)
        meta.textColor = Slate.Native.Overlay.tertiary
        meta.numberOfLines = 1
        meta.isUserInteractionEnabled = false
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        star.slateHelp(CommandNavigatorPresentation.bookmarkHelp)

        let content = UIStackView(arrangedSubviews: [gutter, title, meta, reRun, copyOutput, star])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Slate.Metric.space2
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Slate.Metric.space3, bottom: 0, trailing: Slate.Metric.space2,
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The gutter is a fixed leading column so every command line starts at one x, whatever its
            // own mark turned out to be.
            gutter.widthAnchor.constraint(equalToConstant: Slate.Metric.iconSize),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
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
        SlateSelectionPlateSurface.apply(selected, to: self)
        showGutter(block)
        title.attributedText = Self.marked(block.commandText, query: query, selected: selected)
        accessibilityLabel = block.commandText
        // The two affordances live on the SELECTED (hover or keyboard) row only, so a resting list
        // stays clean; the meta collapses under them when they are up.
        let line = Self.metaLine(block, firstSeen: firstSeen)
        meta.text = line
        meta.isHidden = selected || line.isEmpty
        reRun.isHidden = !selected
        copyOutput.isHidden = !selected
        // `SlatePlateVerbButton` has no disabled ladder of its own — its glyph is drawn in the caller's
        // tint — so a re-run with nothing to run says so in the ink AND declines the tap.
        reRun.isEnabled = !block.commandText.isEmpty
        reRun.tint = block.commandText.isEmpty
            ? Slate.Native.Overlay.tertiary : Slate.Native.Overlay.secondary
        star.active = starred
    }

    /// The status gutter — green ✓ / red ✗ / a grey dot — through the pure
    /// ``OutlinePresentation/gutter(for:)`` classification, so the navigator and the Outline never
    /// disagree about what counts as success. The colour is the only theme-coupled part, and it is
    /// ``Slate/Native/StatusInk`` rather than the on-glass pair because this card is PAPER: the ink
    /// follows the plate it stands on, not the island it floats over.
    private func showGutter(_ block: CommandBlock) {
        let bold = UIImage.SymbolConfiguration(pointSize: Slate.Typeface.small, weight: .bold)
        switch OutlinePresentation.gutter(for: block) {
        case .succeeded:
            gutter.image = UIImage(systemSymbol: .checkmark)
            gutter.preferredSymbolConfiguration = bold
            gutter.tintColor = Slate.Native.StatusInk.ok
        case .failed:
            gutter.image = UIImage(systemSymbol: .xmark)
            gutter.preferredSymbolConfiguration = bold
            gutter.tintColor = Slate.Native.StatusInk.err
        case .running:
            gutter.image = UIImage(systemSymbol: .circleFill)
            gutter.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .regular,
            )
            gutter.tintColor = Slate.Native.Overlay.tertiary
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
    /// ``FuzzyMatcher/runs(of:ranges:)``'s; the ink is this renderer's.
    ///
    /// Monospaced, because a command line is terminal text. A still-forming block has no command text
    /// yet and shows an em-dash; no real query can match it, so it appears only in the zero-query list.
    private static func marked(_ text: String, query: String, selected: Bool) -> NSAttributedString {
        let line = text.isEmpty ? "—" : text
        let base = UIFont.monospacedSystemFont(
            ofSize: Slate.Typeface.body, weight: selected ? .medium : .regular,
        )
        let hit = UIFont.monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .semibold)
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
                color: run.matched ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary,
            ))
        }
        return spliced
    }

    /// One of the row's own buttons, against the block it is currently showing.
    private func fire(_ action: (CommandBlock) -> Void) {
        guard let block else { return }
        action(block)
    }

    @objc
    private func reRunTapped() { fire(actions.onReRun) }

    @objc
    private func copyOutputTapped() { fire(actions.onCopyOutput) }

    @objc
    private func starTapped() { fire(actions.onToggleStar) }

    // MARK: The pointer

    /// Hover moves the keyboard's selection onto this row — but only on genuine pointer MOVEMENT. A
    /// keyboard scroll slides a new row under a parked pointer and the recogniser fires `.changed` for
    /// it; admitting that would yank the selection back to wherever the pointer was left.
    ///
    /// The location is asked in WINDOW space (`nil`), which is the discriminator the gate wants: a
    /// parked pointer keeps one window point while the list moves beneath it. The Mac reads
    /// `NSEvent.mouseLocation` for the same reason.
    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began,
             .changed:
            guard gate.admitHover(at: recogniser.location(in: nil)) else { return }
            actions.onHover(index)
        default:
            break
        }
    }

    @objc
    private func tapped() { fire(actions.onJump) }
}
#endif
