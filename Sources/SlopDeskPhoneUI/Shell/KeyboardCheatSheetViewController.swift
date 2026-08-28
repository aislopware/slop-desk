// KeyboardCheatSheetViewController — ⌘/, the one overlay the phone presents natively.
//
// It left the shared overlay host when the Mac's half became an `NSPanel`, and the two now meet only
// at ``CheatSheetContent`` — the rows, the glyphs and the column deal — which is the layer docs/56
// says a divergent surface shares. Neither half spells the table out, so a printed glyph can never
// drift from the chord the dispatcher actually fires.
//
// ONE COLUMN, and that is the divergence rather than an omission. The Mac's card is 640pt of paper
// summoned over a full workspace and holds two columns side by side; a phone sheet is a narrow strip
// and an iPad's form sheet is barely wider, so a second column there would be two runs of truncated
// titles. ``CheatSheetContent/dealt(_:into:)`` takes the count, so asking for one is a real answer
// rather than a special case.
//
// A NATIVE SHEET, not the in-window paper card the rest of the family wears. The in-window
// presentation exists because a summoned card has to look like it belongs to the workspace it floats
// over; on a phone there is no workspace visible around it — the sheet IS the screen — and the
// platform's own sheet brings the grabber, the swipe-down dismissal and the safe-area insets a
// hand-rolled card would have to re-earn. It is also why this one surface is a `UIViewController`
// while every other overlay is a view in ``PhoneOverlayLayerView``.
//
// ⚠️ `cheatSheetVisible` IS `private(set)` ON THE COORDINATOR, so the shell can only ever be told
// about a dismissal, never infer one. ``onDismiss`` must fire for the swipe and for a hardware Esc
// alike — `presentationControllerDidDismiss` covers the swipe, which `viewWillDisappear` does not
// distinguish from the shell's own programmatic dismissal.
//
// ⚠️ THE ROWS ARE BUILT ONCE, IN `viewDidLoad`, AND NEVER FOLLOWED. ``CheatSheetContent/sections`` is
// a `let` over two `static let` registry tables — it cannot change while the sheet is up — so there is
// nothing here to observe and no `follow()` to arm. That is also why the whole sheet is a stack view
// inside a scroll view rather than a diffable data source: the row count is BOUNDED by the binding
// registry (docs/62 §3.4), and a table view would cost a cell class and a snapshot to draw a list that
// is the same every time it is opened.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import UIKit

@MainActor
final class KeyboardCheatSheetViewController: UIViewController {
    /// Called for a dismissal the USER performed. Bound by the shell to `overlay.closeCheatSheet()`,
    /// which is the only writer of the coordinator's flag.
    var onDismiss: (() -> Void)?

    private let coordinator: OverlayCoordinator

    init(coordinator: OverlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
        presentationController?.delegate = self

        // Done closes through the COORDINATOR, not through `dismiss(animated:)`. The flag is the single
        // source of truth and the shell reconciles the presentation off it; dismissing here directly
        // would leave `cheatSheetVisible` true and the shell would immediately present the sheet again.
        let done = UIButton(configuration: .plain())
        done.translatesAutoresizingMaskIntoConstraints = false
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(closeSheet), for: .touchUpInside)

        let title = SlateCardTitleView(CheatSheetContent.title, trailing: done)

        let column = UIStackView(arrangedSubviews: sections().map(Self.section))
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Slate.Metric.space3
        column.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .clear
        // The sheet's own dismissal gesture and this scroll view are the same drag; letting the
        // keyboard-dismiss mode stay `.none` keeps the sheet's grabber in charge of the interaction.
        scroll.alwaysBounceVertical = true
        scroll.addSubview(column)

        view.addSubview(title)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // The content guide sets the SCROLLABLE extent and the frame guide the width the rows lay
            // out at — tying width to the frame and leaving height free is what scrolls this vertically
            // and only vertically.
            column.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Slate.Metric.space2,
            ),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Slate.Metric.space4,
            ),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    /// ⚠️ THE SHEET HAS TO TAKE THE RESPONDER, or its Esc is a chord nothing will ever deliver.
    /// `keyCommands` are dispatched from the FIRST RESPONDER upwards, and a `UIViewController` is not
    /// one by default (`canBecomeFirstResponder` is `false`) — so without this pair the chain still
    /// starts at the terminal underneath and walks past this sheet entirely. There is no text field
    /// here to take it on the sheet's behalf, unlike every card in ``PhoneOverlayLayerView``.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// Esc, for anyone driving an iPad from a hardware keyboard. The sheet OWNS the dismissal, which is
    /// exactly the responder ``UIKeyCommand/slateCancel(action:)`` says to attach it to.
    override var keyCommands: [UIKeyCommand]? { [.slateCancel(action: #selector(closeSheet))] }

    @objc private func closeSheet() { coordinator.closeCheatSheet() }

    // MARK: - The rows

    /// The single source the rows render from, dealt into the one column a hand-held sheet has room
    /// for. Going through the DEAL rather than reading `sections` straight keeps ONE path to the table,
    /// so a section added to the registry cannot appear on one platform and not the other.
    private func sections() -> [CheatSheetSection] {
        CheatSheetContent.dealt(CheatSheetContent.sections, into: 1).first ?? []
    }

    /// One category run: its caps heading, then its rows.
    private static func section(_ section: CheatSheetSection) -> UIView {
        let heading = SlateCapsLabelView(section.title)

        let stack = UIStackView(arrangedSubviews: [heading] + section.rows.map(row))
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        // The heading's own breathing room, spent as a custom spacing rather than as stack spacing so
        // the rows below stay flush against each other on the row rung.
        stack.setCustomSpacing(Slate.Metric.space1, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Slate.Metric.space3 + Slate.Metric.space2, bottom: 0,
            trailing: Slate.Metric.space3 + Slate.Metric.space2,
        )
        return stack
    }

    /// One binding: what it does, and the key that does it. No plate — nothing here is selected, and a
    /// resting row in this sheet is just its two facts.
    private static func row(_ row: CheatSheetRow) -> UIView {
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = row.title
        title.font = .systemFont(ofSize: Slate.Typeface.base)
        title.textColor = Slate.Native.Overlay.secondary
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        var arranged: [UIView] = [title]
        if let glyph = row.glyph {
            // A gap that absorbs the slack, so the title lays out at its own width and the cap stays
            // trailing — the Auto Layout spelling of `Spacer(minLength:)`.
            let gap = UIView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                gap.widthAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.space2),
            ])
            arranged.append(gap)
            // The keycap is the POINT of the row: this surface exists to teach keys, and a chord
            // printed as loose secondary text is a fact about a key, where a cap IS the key. It resists
            // compression outright, so a long title truncates before a chord loses its ⌘.
            arranged.append(SlateKeycapView(label: glyph))
        }

        let line = UIStackView(arrangedSubviews: arranged)
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = Slate.Metric.space2
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
        ])
        // Said as ONE thing to VoiceOver: "Split pane right, shift command D" is the fact; two adjacent
        // elements read as a label and a mystery glyph.
        line.isAccessibilityElement = true
        line.accessibilityLabel = row.glyph.map { "\(row.title), \($0)" } ?? row.title
        return line
    }
}

extension KeyboardCheatSheetViewController: UIAdaptivePresentationControllerDelegate {
    /// The swipe. Fires only for a user-driven dismissal — a programmatic `dismiss(animated:)` does
    /// not call it, which is exactly the distinction the shell needs to avoid a re-entrant close.
    func presentationControllerDidDismiss(_: UIPresentationController) {
        onDismiss?()
    }
}
#endif
