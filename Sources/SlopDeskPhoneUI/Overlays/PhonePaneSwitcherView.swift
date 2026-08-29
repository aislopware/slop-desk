// PhonePaneSwitcherView — the phone's ⌃⇥ switcher, in UIKit (docs/62 stage F).
//
// The Mac's readout, plus the controls a device with no modifier to RELEASE needs in order to finish the
// gesture. It is mounted for exactly as long as the walk: `store.paneSwitcher` going non-nil is what
// draws it, and going nil is what takes it away.
//
// ⚠️ WHY THIS SURFACE EXISTS AT ALL. The binding row that opens the gesture is `Platform::Both`
// (`pane.switcher`), and the palette carries the same row as its touch entry point — so the phone has
// opened this gesture all along. What it had for a while was no card: `store.paneSwitcher` went non-nil,
// every pane receded behind ``PaneVeilView/recede()`` (which reads that one flag through the focus
// policy), and nothing drew, stepped, committed or cancelled. A veiled workspace with no way out is not
// a missing feature, it is a soft lockup.
//
// WHAT IT DOES NOT OWN. Every fact on the card is ``PaneSwitcherRowsBuilder``'s and
// ``PaneSwitcherMetrics``'s, exactly as the Mac's is: the rows and their two registers, the ⌘-number and
// the rung past which it stops existing, the width, the height the rows scroll at, the words, and — the
// one decision this half needed and the Mac did not — what a TAP means
// (``PaneSwitcherRowsBuilder/walk(to:in:)``).
//
// THE THREE ANSWERS THIS HALF HAD TO GIVE, since a phone cannot release a ⌃:
//
//   1. COMMIT IS A TAP ON THE ROW. It routes through ``WorkspaceStore/commitPaneSwitcher()`` like every
//      other commit — the WALK above is what carries the highlight there first, so the preview unwind and
//      the closed-pane refusal still happen exactly once, in the store.
//   2. A TAP ON THE FLOOR CANCELS. Every other card in this family dismisses on a tap beside it WITHOUT
//      acting, and one member where the same gesture acts would be the family's worst kind of surprise.
//      The store agrees on its own terms: a forward open highlights the PREVIOUS pane rather than the one
//      you are in, so committing a stray tap would teleport a reader out of the pane they were reading.
//      ⚠️ THIS IS WHY THE SWITCHER HAS ITS OWN FLOOR rather than sharing ``PhoneOverlayCardHostView``'s:
//      the two floors mean opposite things, and the switcher is not one of the coordinator's flags at
//      all — it is the STORE's live gesture.
//   3. STEPPING IS A BUTTON. ⇥ needs a hardware keyboard, and this app's rule for a chord-only
//      affordance on the phone is a TAP FALLBACK. ⇥ moves the card's one highlight rather than acting on
//      a row, so its fallback lives on the card's TITLE BAR rather than on a row. No swipe: this family's
//      targets are real controls on purpose, and a gesture recogniser here would be a vocabulary of one.
//
// ⌨️ THE HARDWARE KEYBOARD'S PATH IS NOT THIS FILE'S. `pane.switcher` is `chord: nil` in the binding
// registry on purpose (one row cannot mean open/step/commit, and a ⌃-only chord has no place in a table
// whose invariant is "every chord carries ⌘ or ⌥"), so it is `TerminalInputHost.takesPaneSwitcherKey`
// that claims Esc/Return/⇥/the arrows while this card is up, one rung above the pane's own copy mode.
// This card takes NO keyboard focus and cannot take one away — which is also why it declares no
// `keyCommands` of its own.
//
// ⚠️ A STACK, NOT A TABLE, and that is docs/62 §3.4 rather than a shortcut: the row count is BOUNDED by
// the panes that are open, the ring is frozen for the gesture, and a step moves the plate rather than
// reordering anything. The palette next door is the unbounded case and pays for a diffable data source.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class PhonePaneSwitcherView: UIView {
    private let store: WorkspaceStore

    /// It CANCELS — see note 2 in the file header.
    private lazy var floor = SlateClickTargetView { [weak self] in self?.cancel() }
    private let card = UIView()
    private let rows = UIStackView()
    private let scroll = UIScrollView()
    private let empty = SlateNoResultsLineView(
        message: PaneSwitcherCopy.noPanes, ink: Slate.Native.Overlay.tertiary,
    )
    /// The card's two live measurements, both taken against THIS view — which is the window, since the
    /// layer is full-bleed. The same relationship the Mac's panel has to its host window.
    ///
    /// `lazy`, not implicitly-unwrapped: each one hangs off a stored view, so it cannot be built at the
    /// declaration, but neither is ever absent once `build()` has run.
    private lazy var cardWidth = card.widthAnchor.constraint(equalToConstant: .zero)
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: .zero)

    /// The rows currently drawn, so a step can find the highlighted one without re-resolving.
    private var drawn: [PaneSwitcherRow] = []

    init(store: WorkspaceStore) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// At rest the floor is interaction-disabled and the card is hidden, so `super.hitTest` answers with
    /// `self` — which must become `nil`, or a switcher that is not walking eats the workspace.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        SlatePaperCardSurface.layoutShadow(of: card)
        remeasure()
    }

    // MARK: - Building

    private func build() {
        floor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(floor)

        SlatePaperCardSurface.apply(to: card)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.isHidden = true
        addSubview(card)

        let steps = UIStackView(arrangedSubviews: [
            SlatePlateIconButton(symbol: .chevronUp) { [weak self] in self?.step(forward: false) },
            SlatePlateIconButton(symbol: .chevronDown) { [weak self] in self?.step(forward: true) },
        ])
        steps.axis = .horizontal
        steps.alignment = .center
        steps.spacing = Slate.Metric.space1
        steps.translatesAutoresizingMaskIntoConstraints = false
        // The two arrows are named by what they MOVE, not by the ring's direction: "forward" is a fact
        // about the frozen order, and nobody is holding it.
        steps.arrangedSubviews.first?.accessibilityLabel = PaneSwitcherCopy.stepBackward
        steps.arrangedSubviews.last?.accessibilityLabel = PaneSwitcherCopy.stepForward

        let title = SlateCardTitleView(PaneSwitcherCopy.title, trailing: steps)

        rows.axis = .vertical
        rows.alignment = .fill
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .clear
        scroll.addSubview(rows)

        empty.isHidden = true

        let column = UIStackView(arrangedSubviews: [title, scroll, empty])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        NSLayoutConstraint.activate(floor.slateEdges(of: self))
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardWidth,

            column.topAnchor.constraint(equalTo: card.topAnchor),
            // The card's own bottom margin rides OUTSIDE the scroll view: inside it the content would
            // exceed the exact frame by exactly the margin, and a card with nothing to scroll would
            // scroll.
            column.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -Slate.Metric.space3,
            ),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            listHeight,
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    // MARK: - The live read

    /// The one tracked read. Both the gesture's PRESENCE and its highlight index are read inside `read`,
    /// because a step changes only the second — an arm holding the first alone would draw the card once
    /// and then never move its plate.
    private func follow() {
        ObservationFollow.arm(self) { view in
            let live = view.store.paneSwitcher
            // The rows are rebuilt on every step because the STORE's ring is the source. The ring itself
            // is frozen for the gesture, so a step moves the plate rather than reordering anything — and
            // resolving them inside `read` is what registers the highlight as a dependency.
            return (
                walking: live != nil,
                model: live.map { PaneSwitcherRowsBuilder.rows(for: $0, store: view.store) } ?? [],
            )
        } apply: { view, reading in
            view.reconcile(walking: reading.walking, model: reading.model)
        }
    }

    private func reconcile(walking: Bool, model: [PaneSwitcherRow]) {
        floor.isUserInteractionEnabled = walking
        card.isHidden = !walking
        drawn = model
        guard walking else { return }

        // The honest zero state. The ring is frozen at open and its panes can close under it, so the rows
        // CAN empty mid-gesture — and an empty card that still veils the workspace is the defect this
        // surface exists to answer, said a second time.
        empty.isHidden = !model.isEmpty
        scroll.isHidden = model.isEmpty

        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in model {
            rows.addArrangedSubview(PhonePaneSwitcherRowView(row) { [weak self] in self?.commit(row) })
        }
        remeasure()
        reveal()
    }

    /// The card's width and the list's height, both a function of the WINDOW this layer fills. Re-taken
    /// on every layout pass as well as on every step, because a rotation changes both.
    private func remeasure() {
        cardWidth.constant = PaneSwitcherMetrics.compactWidth(container: bounds.width)
        listHeight.constant = PaneSwitcherMetrics.listHeight(
            rows: drawn.count, rowHeight: Slate.Metric.heightRowStacked, container: bounds.height,
        )
    }

    /// Keeps the marked row on screen as the walk passes the fold — the same job the Mac's
    /// `revealHighlight` does, driven off the store's own index so a step from ANY source scrolls the
    /// same way.
    private func reveal() {
        guard let index = drawn.firstIndex(where: \.isHighlighted),
              index < rows.arrangedSubviews.count
        else { return }
        layoutIfNeeded()
        scroll.scrollRectToVisible(rows.arrangedSubviews[index].frame, animated: false)
    }

    // MARK: - The gesture's three endings

    /// Move the highlight one step. ``WorkspaceStore/openOrStepPaneSwitcher(forward:armedByModifier:)``
    /// STEPS an open switcher and ignores the arming flag while doing so, so a phone step cannot disarm a
    /// gesture a held modifier opened.
    private func step(forward: Bool) {
        // A tap that lands after the gesture already ended must do NOTHING. Without this guard the same
        // call would OPEN a fresh switcher — and a commit would then land on a pane nobody aimed at.
        guard store.paneSwitcher != nil else { return }
        store.openOrStepPaneSwitcher(forward: forward, armedByModifier: false)
    }

    /// Walk the highlight onto the tapped row, then commit through the store's ONE commit door. HOW FAR
    /// and WHICH WAY is ``PaneSwitcherRowsBuilder/walk(to:in:)``'s; a `nil` walk means the ring no longer
    /// holds that pane, which is a no-op rather than a guess.
    ///
    /// The walk is measured against the LIVE gesture rather than the one this card was drawn from: a ⌃⇥
    /// can arrive between the draw and the tap, and a walk counted off a stale highlight would land the
    /// commit that many rows past the one under the finger.
    private func commit(_ row: PaneSwitcherRow) {
        guard let live = store.paneSwitcher,
              let walk = PaneSwitcherRowsBuilder.walk(to: row.id, in: live)
        else { return }
        for _ in 0..<walk.steps {
            store.openOrStepPaneSwitcher(forward: walk.forward, armedByModifier: false)
        }
        store.commitPaneSwitcher()
    }

    /// Abandon the walk, leaving the active pane — and any pane the preview walked through — untouched.
    private func cancel() {
        store.cancelPaneSwitcher()
    }
}

// MARK: - One candidate

/// One pane: what it is, where it lives, and the ⌘-key that reaches it directly.
///
/// Nothing here is coloured — the highlight is a lifted plate and a heavier title, the house rule that a
/// readout marks importance with LIGHT and WEIGHT rather than hue.
@MainActor
final class PhonePaneSwitcherRowView: SlateRowButton {
    private let plate = UIView()

    init(_ model: PaneSwitcherRow, action: @escaping () -> Void) {
        super.init(action: action)

        plate.translatesAutoresizingMaskIntoConstraints = false
        SlateSelectionPlateSurface.install(on: plate)
        SlateSelectionPlateSurface.apply(model.isHighlighted, to: plate)
        plate.isUserInteractionEnabled = false
        addSubview(plate)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.attributedText = .slateNerdAware(
            model.title,
            font: .systemFont(
                ofSize: Slate.Typeface.body, weight: model.isHighlighted ? .medium : .regular,
            ),
            color: model.isHighlighted
                ? Slate.Native.Overlay.primary
                : Slate.Native.Overlay.secondary,
        )
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        var stacked: [UIView] = [title]
        if let place = Self.placeLine(model) {
            let line = UILabel()
            line.translatesAutoresizingMaskIntoConstraints = false
            line.attributedText = place
            line.numberOfLines = 1
            // Truncate the place from the HEAD: a deep path's LAST components are the ones that say
            // where the pane actually is.
            line.lineBreakMode = .byTruncatingHead
            stacked.append(line)
        }

        let text = UIStackView(arrangedSubviews: stacked)
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 0

        let gap = UIView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.space2).isActive = true

        var arranged: [UIView] = [text, gap]
        // Absent past ⌘9, where the chord does not exist (the app binds ⌘1–9 only) — an unpressable key
        // drawn on a row is a lie.
        if model.number <= PaneSwitcherRowsBuilder.highestShortcut {
            arranged.append(SlateKeycapView(label: "⌘\(model.number)", lit: model.isHighlighted))
        }

        let row = UIStackView(arrangedSubviews: arranged)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space3
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isUserInteractionEnabled = false
        plate.addSubview(row)

        NSLayoutConstraint.activate([
            // The plate keeps its own inset from the card's edge, and the row's text lands where the
            // palette's does — one list anatomy across the family's cards.
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRowStacked),

            row.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -Slate.Metric.space3),
            row.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = [model.title, Self.placeLine(model)?.string]
            .compactMap(\.self)
            .joined(separator: ", ")
        accessibilityTraits = model.isHighlighted ? [.button, .selected] : .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The PLACE line, spliced into ONE run so its two halves flow and truncate together: the project a
    /// shade heavier, then the sub-path under it in the plain weight. WEIGHT rather than ink, because
    /// both halves are equally quiet next to the identity — what differs is which of them the eye should
    /// catch running down a column of rows.
    ///
    /// A pane with no project (a video pane, a shell whose cwd has not landed) shows its note alone
    /// rather than an empty lead-in; a pane with neither draws no second line at all.
    private static func placeLine(_ model: PaneSwitcherRow) -> NSAttributedString? {
        let size = Slate.Typeface.footnote
        let ink = Slate.Native.Overlay.tertiary
        guard let project = model.project else {
            return model.note.map {
                .slateNerdAware($0, font: .systemFont(ofSize: size), color: ink)
            }
        }
        let head = NSMutableAttributedString(attributedString: .slateNerdAware(
            project, font: .systemFont(ofSize: size, weight: .medium), color: ink,
        ))
        guard let note = model.note else { return head }
        head.append(.slateNerdAware(
            "\(PaneSwitcherCopy.placeSeparator)\(note)", font: .systemFont(ofSize: size), color: ink,
        ))
        return head
    }
}
#endif
