// NavigatorRowCell — one navigator row, in UIKit.
//
// otty-bare: a title on one touch-height line and ONE trailing slot. The richness lives in the
// context menu and the accessibility hint, both of which are values from below
// (``SidebarRowMenu/entries(for:store:)`` and ``SidebarRowReading/tooltip``) rather than decisions
// taken here.
//
// WHAT THIS CELL OWNS is the three things a framework has to answer for itself:
//
//   1. THE LIVE READ. The row re-resolves its own ``SidebarRowReading`` under an
//      ``ObservationFollow``, so a pane's status tick repaints this leaf and never the list. That
//      is the same leaf-scope contract the deleted SwiftUI rows kept — and the reason SELECTION is
//      read here rather than passed in: a parameter-carried `active` strands the previously selected
//      row lit, and a diffable snapshot keyed on the row's chrome would re-diff the whole list on
//      every agent heartbeat (docs/62 §3.4: the identifier is the id, never the rendered content).
//   2. THE INK'S POLARITY. The selected row is stamped out of the terminal island's material, so it
//      carries the ISLAND's appearance rather than the chrome's: every semantic ink inside it then
//      resolves against the plate it actually stands on, exactly as the SwiftUI half's
//      `\.colorScheme` override did — one line here instead of a dozen hand-flipped inks.
//   3. THE RENAME FIELD, with the resolved-once rule the Finder idiom needs: Return commits, a
//      dismissal cancels — but the teardown's own focus loss must not re-commit what Return already
//      resolved.
//
// THREE THINGS THE MAC ROW OWNS THAT THIS ONE DOES NOT, each a pointer→thumb re-layout the deleted
// SwiftUI half had already made and this rebuild keeps:
//
//   - THE HOVER SWAP → A SWIPE. ``MacSidebarRowView`` swaps its trailing cluster for a close × under
//     the pointer. There is no pointer here, so the close is `.swipeActions(edge: .trailing)`'s
//     descendant — a trailing `UISwipeActionsConfiguration` vended by the COLUMN, because the
//     configuration is asked of the collection view and not of the cell.
//   - THE TOOLTIP → TWO PLACES. ``SidebarRowReading/presence`` becomes the row's visible second line
//     (the ``Slate/Metric/heightRowStacked`` rung), and the rest of the tooltip rides
//     `accessibilityHint`.
//   - THE TRAVELLING PLATE. The Mac's selection is ONE `CALayer` that moves between the rows of a
//     project island. A list layout has no island view to own it, so selection here is the per-row
//     chip the SwiftUI `List(selection:)` also drew — the same material and the same rim, arrived at
//     rather than travelled to.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class NavigatorRowCell: UICollectionViewListCell, UITextFieldDelegate {
    static let reuseIdentifier = "NavigatorRowCell"

    /// The row's STRUCTURAL identity. Everything volatile is re-read in ``follow()``.
    private(set) var row: RailRow?
    private var store: WorkspaceStore?
    /// The kind's generic title, for a row whose whole title chain comes up empty.
    private var fallbackTitle = ""
    private var reading: SidebarRowReading?

    /// ⚠️ THE ARM IS THE SUBSCRIPTION, and a reused cell must not be woken by the pane it used to show.
    /// ``ObservationFollow/arm(_:read:apply:)`` is NOT idempotent — a second arm does not displace the
    /// first, it runs beside it — so this cell holds its following and names it on both edges:
    /// ``follow()`` arms `replacing:` it (the cell registration re-configures a MOUNTED cell) and
    /// ``prepareForReuse()`` calls ``ObservationFollow/stop()`` on it. The owner's weak capture alone
    /// would not do it: a reused cell IS live, so a stale wake would find a `self` and repaint it with
    /// the previous pane's reading (docs/62 §4 hazard 2).
    private var rowFollow: ObservationFollow?

    private let title = UILabel()
    private let presence = UILabel()
    private let column = UIStackView()
    private let renameField = UITextField()
    private let slot = UILabel()
    private let slotImage = UIImageView()
    private let mark = SlateStatusMarkView()
    private let lock = UIImageView()
    private let sync = UIImageView()
    private let shortcut = UILabel()
    private let trailing = UIStackView()

    /// The row's minimum height, swapped between the one-register and two-register rungs as the
    /// presence line comes and goes. A CONSTRAINT rather than an `intrinsicContentSize`, because the
    /// list layout self-sizes this cell and the second line has to be able to push past the rung.
    private var floorHeight: NSLayoutConstraint?

    /// Whether the open rename was already RESOLVED by Return — so the focus-loss handler that fires
    /// when the field is torn down does not re-commit the draft (which would make Return commit
    /// twice). A genuine dismissal leaves it `false`.
    private var renameResolved = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Construction

    private func build() {
        title.lineBreakMode = .byTruncatingTail
        title.numberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The tooltip's opening line, made visible: on the Mac this is hover-only text, and there is
        // no hover here. `small` on the secondary ink is the caption register — one step under the
        // title, so the row still reads as one identity with a place set under it.
        presence.font = Slate.Typeface.instrumentNative(Slate.Typeface.small)
        presence.textColor = Slate.Native.Text.secondary
        presence.lineBreakMode = .byTruncatingTail
        presence.numberOfLines = 1
        presence.isHidden = true
        presence.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(title)
        column.addArrangedSubview(presence)
        contentView.addSubview(column)

        renameField.borderStyle = .none
        renameField.delegate = self
        renameField.isHidden = true
        renameField.font = .systemFont(ofSize: Slate.Typeface.base)
        renameField.textColor = Slate.Native.Text.primary
        renameField.tintColor = Slate.Native.Text.primary
        renameField.autocapitalizationType = .none
        renameField.autocorrectionType = .no
        renameField.spellCheckingType = .no
        renameField.returnKeyType = .done
        renameField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(renameField)

        slot.lineBreakMode = .byTruncatingTail
        slot.numberOfLines = 1
        slot.setContentCompressionResistancePriority(.required, for: .horizontal)
        for indicator in [lock, sync, slotImage] { indicator.contentMode = .center }

        shortcut.textAlignment = .right
        shortcut.font = Slate.Typeface.instrumentNative(Slate.Typeface.base, weight: .semibold)
        shortcut.isAccessibilityElement = false

        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = 6
        trailing.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(trailing)

        let floor = contentView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Slate.Metric.heightRowTall,
        )
        floorHeight = floor
        NSLayoutConstraint.activate([
            floor,
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space3,
            ),
            column.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            column.topAnchor.constraint(
                greaterThanOrEqualTo: contentView.topAnchor, constant: Slate.Metric.space1,
            ),
            renameField.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            renameField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            renameField.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            trailing.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            trailing.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            column.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor,
                constant: -Slate.Metric.rowTitleGap,
            ),
        ])
    }

    // MARK: The live read

    /// Take one row and start following it. Called by the cell registration, which runs on every
    /// re-configure of an already-mounted cell as well as on a fresh one — so this supersedes rather
    /// than stacks.
    func configure(row: RailRow, store: WorkspaceStore, fallbackTitle: String) {
        self.row = row
        self.store = store
        self.fallbackTitle = fallbackTitle
        reading = nil
        renameResolved = false
        follow()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Disarm: a wake already scheduled for the OLD pane's arm lands on a stopped following and
        // returns without re-arming. Nothing else can end a one-shot tracker.
        rowFollow?.stop()
        rowFollow = nil
        row = nil
        store = nil
        reading = nil
        mark.style = nil
        renameField.isHidden = true
        renameField.resignFirstResponder()
    }

    /// Re-resolve this row against the store and repaint, re-arming for the next change.
    ///
    /// ⚠️ EVERY TRACKED READ IS INSIDE `read`. Hoisting one into `apply` — which runs OUTSIDE the
    /// tracking block — silently unsubscribes from it, and the row then goes stale on exactly that
    /// input with nothing to show for it.
    ///
    /// `replacing:`, never a bare `arm`: the cell registration runs this on every re-configure of an
    /// already-mounted cell, and a second plain arm would leave the OLD pane's chain applying beside
    /// the new one.
    private func follow() {
        rowFollow = ObservationFollow.arm(self, replacing: rowFollow) { cell -> SidebarRowReading? in
            guard let row = cell.row, let store = cell.store else { return nil }
            // The flash tick FIRST, and read for its own sake: a completion flash is a store counter
            // rather than a field of the reading, so a row that only tracked the reading would not
            // re-read when the flash fires. The deleted SwiftUI row opened with the same line.
            _ = store.completionFlashTick
            return SidebarRowPresentation.reading(
                for: row, store: store, fallbackTitle: cell.fallbackTitle,
            )
        } apply: { cell, next in
            guard let next, next != cell.reading else { return }
            cell.reading = next
            cell.apply(next)
        }
    }

    /// Paint one reading.
    private func apply(_ reading: SidebarRowReading) {
        // The chip is stamped out of the terminal island's material, so what stands ON it reads
        // against the ISLAND's polarity: under a dark profile the selected row's label flips light
        // instead of drawing near-black on a dark plate. One style, and every semantic ink inside
        // resolves itself.
        let polarity: UIUserInterfaceStyle =
            if reading.active {
                Slate.glassColorScheme == .dark ? .dark : .light
            } else {
                .unspecified
            }
        if overrideUserInterfaceStyle != polarity { overrideUserInterfaceStyle = polarity }

        var plate = UIBackgroundConfiguration.clear()
        plate.backgroundColor = reading.active ? Slate.Native.Surface.island : .clear
        plate.cornerRadius = Slate.Metric.islandRadiusCompact
        // A chip stamped out of the island's material carries the island's rim too, or the two
        // surfaces stop being the same object the moment the ground stops being what separates them.
        // NO shadow: at-rest depth is the surface ladder (MERIDIAN L5).
        plate.strokeColor = reading.active ? Slate.Native.Terminal.edge : .clear
        plate.strokeWidth = reading.active ? Slate.Metric.hairline : 0
        backgroundConfiguration = plate

        column.isHidden = reading.isEditing
        trailing.isHidden = reading.isEditing
        renameField.isHidden = !reading.isEditing
        if reading.isEditing, !renameField.isFirstResponder {
            renameResolved = false
            renameField.text = reading.title
            renameField.becomeFirstResponder()
        }

        title.attributedText = .slateNerdAware(
            reading.agentMarker ? RailRowsBuilder.agentMarkedTitle(reading.title) : reading.title,
            font: .systemFont(ofSize: Slate.Typeface.base, weight: weight(reading.titleWeight)),
            color: ink(reading.titleInk),
        )
        presence.text = reading.presence
        presence.isHidden = reading.presence == nil
        floorHeight?.constant = reading.presence == nil
            ? Slate.Metric.heightRowTall
            : Slate.Metric.heightRowStacked

        // ONE accessibility element for the whole row: the name, what it is doing, and the tooltip's
        // remainder as the hint. VoiceOver reads a row, not four labels.
        isAccessibilityElement = true
        accessibilityTraits = reading.active ? [.button, .selected] : .button
        accessibilityLabel = reading.title
        accessibilityValue = reading.spokenState ?? ""
        accessibilityHint = reading.tooltip ?? ""

        rebuildTrailing(reading)
    }

    /// The row's INK for a title rung — the palette side of ``SidebarRowReading/titleInk``.
    private func ink(_ rung: RowTitleInk) -> UIColor {
        switch rung {
        case let .urgent(role): Slate.Native.attentionInk(role)
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        }
    }

    private func weight(_ rung: RowTitleWeight) -> UIFont.Weight {
        switch rung {
        case .resting: .regular
        case .active: .medium
        case .attention: .semibold
        }
    }

    /// The trailing cluster: the rare MODE glyphs (lock / sync), then badge-or-receipt-or-shell-label,
    /// then the status mark.
    ///
    /// A held ⌘ (an iPad hardware keyboard) replaces the WHOLE cluster with one right-aligned digit:
    /// while the hold is up the question is "what do I press", so the number stands in for every
    /// indicator rather than crowding a new column beside them. Everything returns on ⌘-up.
    private func rebuildTrailing(_ reading: SidebarRowReading) {
        for view in trailing.arrangedSubviews {
            trailing.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let hint = reading.shortcutHint {
            shortcut.text = "\(hint)"
            shortcut.textColor = Slate.Native.Text.secondary
            trailing.addArrangedSubview(shortcut)
            return
        }
        if reading.readOnly {
            configure(lock, symbol: "lock.fill", ink: Slate.Native.Text.secondary)
            lock.accessibilityLabel = SidebarRowPresentation.readOnlyLabel
            trailing.addArrangedSubview(lock)
        }
        if reading.syncInput {
            // The FIXED sync amber, not the lock's muted tone: sync input is a fan-out mode, and its
            // rail indicator has to be as unmissable as the pane's own pill.
            configure(sync, symbol: "rectangle.3.group", ink: Slate.Native.Status.syncInput)
            sync.accessibilityLabel = SidebarRowPresentation.syncInputLabel
            trailing.addArrangedSubview(sync)
        }
        if let filled = slotContent(reading) {
            trailing.addArrangedSubview(filled)
        }
        trailing.addArrangedSubview(mark)
        mark.style = StatusPresentation.statusDot(
            working: reading.workingLabel != nil, badge: reading.badge,
            agentIdle: reading.agentIdle, agentFinish: reading.agentFinish,
        )
    }

    /// The slot's one occupant, in rank order: a PRIVILEGE marker (the only badge that takes the slot
    /// as art), else a finished command's RECEIPT, else the resting process label.
    private func slotContent(_ reading: SidebarRowReading) -> UIView? {
        if let badge = reading.badge, let style = StatusPresentation.tabBadge(badge) {
            return badgeView(style)
        }
        if let receipt = reading.receipt {
            // ONE answer, never two: the bare tick for a clean exit, the command's NAME in red for a
            // failure — both in the outcome's own ink, so the shorter slot is not a fainter one.
            if let symbol = StatusPresentation.outcomeSymbol(receipt.outcome) {
                configure(
                    slotImage, symbol: symbol.rawValue,
                    ink: StatusPresentation.outcomeInk(receipt.outcome),
                    // `.semibold` IS ``StatusDot/receiptCheckWeight`` — see ``configure(_:symbol:…)``
                    // for why the token cannot be passed through on this side.
                    size: StatusDot.receiptCheckSize, weight: .semibold,
                )
                slotImage.isAccessibilityElement = false
                return slotImage
            }
            slot.text = receipt.name
            slot.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .bold)
            slot.textColor = StatusPresentation.outcomeInk(receipt.outcome)
            return slot
        }
        guard let label = reading.processLabel else { return nil }
        // A process name is DATA — the instrument mono at the caption size, on the tertiary ink at
        // rest and in the bold primary once that name is a COMMAND, which is the register it keeps
        // through its own exit.
        let isCommand = RailRowsBuilder.slotLabelIsCommand(label)
        slot.text = label
        slot.font = Slate.Typeface.instrumentNative(
            Slate.Typeface.small, weight: isCommand ? StatusPresentation.slotNameWeight : .regular,
        )
        slot.textColor = StatusPresentation.slotNameInk(isCommand: isCommand)
        return slot
    }

    /// The privilege marker — `#` or `∞`, drawn as the same artwork the Mac slot mounts.
    private func badgeView(_ style: TabBadgeStyle) -> UIView {
        switch style.art {
        case let .symbol(symbol):
            configure(
                slotImage, symbol: symbol.rawValue, ink: style.tint,
                size: StatusDot.badgeSymbolSize,
            )
            return slotImage
        case let .vector(icon):
            return SlateVectorIconView(icon: icon, side: StatusDot.footprint, ink: style.tint)
        }
    }

    /// ⚠️ THE WEIGHT IS A `UIImage.SymbolWeight`, NOT the `UIFont.Weight` the design tokens speak —
    /// a third enum with no conversion either way, exactly the seam ``SlateStatusMarkView`` documents
    /// on the same framework call. So ``StatusDot/receiptCheckWeight``'s `.semibold` is spelled again
    /// at the one call site that needs it, and the two are kept in step by eye. (AppKit's twin takes
    /// an `NSFont.Weight` and has no such seam, which is why `MacSidebarRowView` can pass the token.)
    ///
    /// The ink rides the IMAGE (`.alwaysOriginal`), not a template tint: an image view inside a cell
    /// whose polarity flips would otherwise take whatever tint the flipped subtree hands it.
    private func configure(
        _ view: UIImageView, symbol: String, ink: UIColor,
        size: CGFloat = Slate.Typeface.small, weight: UIImage.SymbolWeight = .semibold,
    ) {
        view.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight),
        )?.withTintColor(ink, renderingMode: .alwaysOriginal)
    }

    // MARK: The rename field

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        renameResolved = true
        commitRename(field.text ?? "")
        field.resignFirstResponder()
        return true
    }

    /// Focus loss commits the draft — the Finder rename field's own behaviour — UNLESS Return already
    /// resolved it (the field's teardown drops focus, and re-firing here would commit twice).
    func textFieldDidEndEditing(_ field: UITextField) {
        guard !renameResolved else { return }
        commitRename(field.text ?? "")
    }

    /// An UNTOUCHED draft resolves as a CANCEL: the seed is the row's LIVE title (intent / running
    /// command / generic fallback), and committing it verbatim would freeze that snapshot as a sticky
    /// `userRenamed` identity. Only an edit expresses a rename.
    private func commitRename(_ text: String) {
        guard let row, let store, let reading else { return }
        if text == reading.title {
            store.clearTabRenameRequest()
        } else {
            SidebarSelection.commitRename(row.id, to: text, in: store)
        }
    }
}
#endif
