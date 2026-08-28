// PhonePeekReplyCardView — the phone's ⌘⌥J "Peek & Reply" card, in UIKit (docs/62 stage F).
//
// The UIKit half of the deleted `PeekReplyOverlay`. It targets the OLDEST pane needing attention, prints
// that pane's cheap headless ``PeekContent`` — title, the agent's blocking question, the last few command
// lines — plus the exact tool call the question is about, and offers a reply field. The point is answering
// a blocked agent INLINE, without a tab switch and without ever leaving the pane you were in.
//
// **OBSERVE AND REPLY, NEVER AN APPROVAL GATE.** Nothing here pauses an agent pending a slopdesk
// confirmation. A submitted line is formatted by the pure ``PeekReplyFormatter`` — plain, `!`-shell, or a
// digit — and sent VERBATIM down the pane's PTY through ``OverlayCoordinator/deliverPeekReply(_:to:)``,
// never through `SendKeysParser`. After each reply the coordinator advances to the next pane needing
// attention, and this card follows that resolution rather than keeping a queue of its own.
//
// NOTHING HERE SPELLS A STRING THE CARD SAYS. The caption's join, the "N of M" counter, the note for a
// pane that reported no question, and the all-caught-up line are ``PeekReplyPresentation``'s; the header
// glyph's reading is ``StatusPresentation``'s and the pending-tool line is ``PendingToolSummary``'s.
// `slopdesk-invariants` fails the build if any of them comes back into a view.
//
// ⚠️ THE QUICK-ANSWER DIGIT IS THE FIELD'S DELEGATE, NOT A `UIKeyCommand`, and the UIKit spelling is
// strictly better than the one it replaces. A bare 1–9 with the field EMPTY answers option N; the same
// digit with anything typed is just a digit. As a key command it would have to be registered
// unconditionally and `wantsPriorityOverSystemBehavior` would then take every "1" the user ever typed.
// `textField(_:shouldChangeCharactersIn:replacementString:)` sees the edit BEFORE the field applies it,
// declines it exactly when the shortcut fires — and, unlike the deleted `.onKeyPress` arm, it fires for
// the SOFTWARE keyboard too, which is the one every phone actually has.
//
// ⚠️ THE ADVANCE CROSSFADES. Without a beat, question / pending tool / recent all mutate in one frame and
// it reads as the SAME pane changing rather than as the next one arriving. The declarative half bought
// that with `.id(target)` and a transition; here it is one `UIView.transition` around the redraw, which is
// the same mechanical opacity and does not remount a single view.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskInspector
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class PhonePeekReplyCardView: UIView, UITextFieldDelegate {
    private let store: WorkspaceStore
    private let overlay: OverlayCoordinator

    /// The pane this card is currently about. Held so a redraw can tell an ADVANCE (crossfade) from a
    /// live update of the same pane (a plain redraw).
    private var target: PaneID?
    /// Whether the pending-tool block is showing its full input instead of the collapsed one-liner.
    /// Collapses on every advance — a fresh target's card never inherits the last pane's disclosure.
    private var expanded = false
    private var hasBegun = false

    // The header
    private let glyph = SlateStatusGlyphView()
    private let title = UILabel()
    private let caption = UILabel()
    private let trailing = UILabel()
    // The body
    private let question = UILabel()
    private let pending = UIControl()
    private let pendingLine = UILabel()
    private let pendingFull = UITextView()
    /// The two padded WRAPPERS the blocks above sit in. Held because hiding a block means hiding its
    /// padding with it — a row hidden inside a visible wrapper leaves its margins behind as a gap.
    private var pendingRow = UIView()
    private var pendingFullRow = UIView()
    private let recentBlock = UIStackView()
    private let recentLines = UIStackView()
    // The reply bar
    private let field = UITextField()
    private let send = UIButton(type: .system)
    /// Everything that is about a TARGET, hidden wholesale for the all-caught-up race.
    private let column = UIStackView()
    private let caughtUp = UIStackView()

    init(store: WorkspaceStore, overlay: OverlayCoordinator) {
        self.store = store
        self.overlay = overlay
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
        accessibilityViewIsModal = true

        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = Slate.Native.Overlay.primary
        title.numberOfLines = 1
        // MIDDLE truncation on the pane's name: a shell title is usually a path, and its tail is what
        // tells two panes apart.
        title.lineBreakMode = .byTruncatingMiddle

        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = Slate.Native.Overlay.secondary
        caption.numberOfLines = 1
        // TAIL truncation, and it is the far side's whole reason for appending the todo scent LAST: a
        // squeeze eats the prose first, the "i/n" count second, and the status word never.
        caption.lineBreakMode = .byTruncatingTail

        let names = UIStackView(arrangedSubviews: [title, caption])
        names.axis = .vertical
        names.alignment = .leading
        names.spacing = 1

        trailing.numberOfLines = 1
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [glyph, names, trailing])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Slate.Metric.space2
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space3, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space3, trailing: Slate.Metric.space4,
        )

        question.font = .preferredFont(forTextStyle: .body)
        // The question WRAPS. It is the one thing on this card the user has to read in full, and a
        // truncated ask is a card that cannot be answered.
        question.numberOfLines = 0
        let questionRow = pad(question)

        buildPending()
        buildRecent()
        buildReplyBar()

        pendingRow = pad(pending)
        pendingFullRow = pad(pendingFull)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        for view in [
            header, SlateCardSeparatorView(frame: .zero), questionRow, pendingRow,
            pendingFullRow, recentBlock, SlateCardSeparatorView(frame: .zero), replyRow(),
        ] { column.addArrangedSubview(view) }

        buildCaughtUp()
        // ⚠️ THE TWO FACES ARE ARRANGED SUBVIEWS OF ONE STACK, never two views pinned to the same four
        // edges. A hidden view keeps its constraints — pinned that way, the all-caught-up card would go
        // on setting a floor under the card's height while it was invisible. A stack's hidden arranged
        // subview contributes nothing, which is the whole difference.
        let body = UIStackView(arrangedSubviews: [column, caughtUp])
        body.axis = .vertical
        body.alignment = .fill
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate(fill(body))
    }

    /// A body block on the card's own horizontal padding. Every one of them takes the same two rungs, so
    /// the leading edge of the question, the tool line and the RECENT caption is one line down the card.
    private func pad(_ view: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [view])
        row.axis = .vertical
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space3, trailing: Slate.Metric.space4,
        )
        return row
    }

    private func fill(_ view: UIView) -> [NSLayoutConstraint] {
        [
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
    }

    /// The pending tool call, both ways round: a collapsed one-liner that expands on a tap, and the full
    /// input in a scroll capped at the shared rung. NO plate, no border, no icon, no status colour — the
    /// header's own mark already says "blocked", and a second alarm on the same card is one too many.
    private func buildPending() {
        pendingLine.font = .monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
        pendingLine.numberOfLines = 1
        pendingLine.lineBreakMode = .byTruncatingMiddle
        pendingLine.translatesAutoresizingMaskIntoConstraints = false
        pendingLine.isUserInteractionEnabled = false
        pending.addSubview(pendingLine)
        pending.addTarget(self, action: #selector(expand), for: .touchUpInside)
        pending.isAccessibilityElement = true
        pending.accessibilityTraits = .button

        pendingFull.font = .monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
        pendingFull.textColor = Slate.Native.Overlay.primary
        pendingFull.backgroundColor = .clear
        // Read-only but SELECTABLE: the expanded view exists so the exact input can be read, and
        // sometimes copied, before answering.
        pendingFull.isEditable = false
        pendingFull.isSelectable = true
        pendingFull.textContainerInset = .zero
        pendingFull.textContainer.lineFragmentPadding = 0
        pendingFull.translatesAutoresizingMaskIntoConstraints = false
        pendingFull.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(collapse)),
        )

        NSLayoutConstraint.activate([
            pendingLine.topAnchor.constraint(equalTo: pending.topAnchor),
            pendingLine.bottomAnchor.constraint(equalTo: pending.bottomAnchor),
            pendingLine.leadingAnchor.constraint(equalTo: pending.leadingAnchor),
            pendingLine.trailingAnchor.constraint(equalTo: pending.trailingAnchor),
            // The cap both scrolling blocks share — one number for both, because a card with two wells
            // of different heights reads as two panels rather than as one card.
            pendingFull.heightAnchor.constraint(
                lessThanOrEqualToConstant: CGFloat(PeekReplyMetrics.scrollMaxHeight),
            ),
        ])
    }

    private func buildRecent() {
        recentLines.axis = .vertical
        recentLines.alignment = .fill
        recentLines.spacing = 2
        recentLines.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(recentLines)

        recentBlock.axis = .vertical
        recentBlock.alignment = .fill
        recentBlock.spacing = Slate.Metric.space1
        recentBlock.isLayoutMarginsRelativeArrangement = true
        recentBlock.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space3, trailing: Slate.Metric.space4,
        )
        recentBlock.addArrangedSubview(SlateCapsLabelView("Recent"))
        recentBlock.addArrangedSubview(scroll)

        NSLayoutConstraint.activate([
            // A scroll view is sized by its CONTENT guide and positioned by its FRAME guide — the pair
            // that has no analogue in the declarative spelling, where a `ScrollView` simply took what it
            // was given. The width equality is what stops the lines scrolling sideways.
            recentLines.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            recentLines.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            recentLines.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            recentLines.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            recentLines.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.heightAnchor.constraint(
                lessThanOrEqualToConstant: CGFloat(PeekReplyMetrics.scrollMaxHeight),
            ),
        ])
    }

    private func buildReplyBar() {
        // A REAL field at the system's size. The card is ours; what sits in it is the system's — the same
        // rule ``SlateLabeledFieldView`` states for the Connect form, and a hand-drawn plate was tried
        // here and read as cramped beside a stock send button.
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.placeholder = "Reply…"
        field.returnKeyType = .send
        field.autocapitalizationType = .sentences
        field.delegate = self
        field.addTarget(self, action: #selector(edited), for: .editingChanged)

        var filled = UIButton.Configuration.borderedProminent()
        filled.image = UIImage(systemSymbol: .paperplaneFill)
        send.configuration = filled
        send.addTarget(self, action: #selector(submit), for: .touchUpInside)
        send.accessibilityLabel = "Send reply"
        send.setContentHuggingPriority(.required, for: .horizontal)
        // ↩ submits through the field's own delegate. NO key command for Return here: a chord and a
        // submit both firing would deliver one typed line TWICE.
        send.isEnabled = false
    }

    private func replyRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [field, send])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space3, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space3, trailing: Slate.Metric.space4,
        )
        return row
    }

    /// The zero-state card, for the near-impossible race where the host clears the last status while this
    /// one is up: the open gate requires a target and the advance closes when none is left.
    private func buildCaughtUp() {
        let mark = UIImageView(
            image: UIImage(
                systemSymbol: .checkmarkCircle,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2),
            ),
        )
        mark.tintColor = Slate.Native.Status.ok
        mark.contentMode = .center
        let line = UILabel()
        line.text = PeekReplyPresentation.allCaughtUp
        line.textColor = Slate.Native.Overlay.secondary
        line.font = .systemFont(ofSize: Slate.Typeface.body)
        line.textAlignment = .center
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        caughtUp.axis = .vertical
        caughtUp.alignment = .center
        caughtUp.spacing = Slate.Metric.space2
        caughtUp.isLayoutMarginsRelativeArrangement = true
        caughtUp.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space4, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space4, trailing: Slate.Metric.space4,
        )
        for view in [mark, line, done] { caughtUp.addArrangedSubview(view) }
    }

    // MARK: - Coming up

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasBegun else { return }
        hasBegun = true
        // The reply field takes the keyboard on arrival: typing — and the empty-field digit shortcut —
        // must reach it without a tap. Unconditional and NOT hopped a runloop, for the reason
        // ``SlateSearchBarView``'s header gives: a `UITextField` is its own responder from `init`, and by
        // this callback the chain it joins already exists.
        field.becomeFirstResponder()
        follow()
    }

    /// ⚠️ THE TRACKED READ RESOLVES THE TARGET, which is the one place this file departs from
    /// ``ObservationFollow``'s "return values, do no work". The resolution IS the value — it folds the
    /// exclusion set over the panes' attention statuses — and its dependency set is exactly the set that
    /// must wake this card: a pane going quiet, a new one going blocked, or a reply landing and adding to
    /// the exclusions. Reading anything narrower would leave the card pointing at a pane that has since
    /// been answered.
    private func follow() {
        ObservationFollow.arm(
            self,
            read: { $0.overlay.peekReplyTarget() },
            apply: { card, resolved in card.show(resolved) },
        )
    }

    // MARK: - Drawing

    private func show(_ resolved: PaneID?) {
        let advanced = resolved != target
        target = resolved
        if advanced {
            // A fresh pane starts collapsed rather than inheriting the last one's disclosure.
            expanded = false
            UIView.transition(
                with: self, duration: Slate.Motion.smallFade.duration,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: { self.draw() },
            )
        } else {
            draw()
        }
    }

    private func draw() {
        column.isHidden = target == nil
        caughtUp.isHidden = target != nil
        guard let target else { return }
        let content = store.peekContent(for: target)
        drawHeader(target, content)
        drawQuestion(content)
        drawPending(target)
        drawRecent(content)
    }

    private func drawHeader(_ target: PaneID, _ content: PeekContent) {
        let status = store.agentStatus(for: target)
        if let reading = StatusPresentation.agentReading(status) {
            glyph.isHidden = false
            glyph.reading = reading
            glyph.tint = StatusPresentation.agentTint(status)
        } else {
            glyph.isHidden = true
        }
        title.text = content.title
        // The todo scent rides the caption only while a LIVE inspector reports one, so an idle,
        // non-Claude or stale-feed pane's caption is byte-identical to what it was before the scent
        // existed.
        let scent = inspector(for: target).flatMap {
            $0.feedState == .live ? PendingToolSummary.scent(todos: $0.todos) : nil
        }
        caption.text = PeekReplyPresentation.caption(status: status, scent: scent)
        // The counter REPLACES the card's name once a real queue exists — a hard cut on the queue edge,
        // never both at once. Both readings come off the SAME predicate the advance chain uses, so the
        // count and the chain cannot disagree.
        if let counter = PeekReplyPresentation.counter(queuePosition) {
            trailing.text = counter
            trailing.font = .monospacedDigitSystemFont(
                ofSize: Slate.Typeface.footnote, weight: .regular,
            )
            trailing.textColor = Slate.Native.Overlay.tertiary
        } else {
            trailing.text = PeekReplyPresentation.title
            trailing.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
            trailing.textColor = Slate.Native.Overlay.secondary
        }
    }

    /// The "N of M" triage position, or `nil` for a queue of one — which is not a queue, and gets the
    /// calm static caption instead.
    private var queuePosition: (position: Int, total: Int)? {
        PeekReplyTarget.queuePosition(
            status: { self.store.agentStatus(for: $0) },
            panes: store.tree.allPaneIDs(),
            excluding: overlay.peekReplyExcluding,
        )
    }

    private func drawQuestion(_ content: PeekContent) {
        let reading = PeekReplyPresentation.question(content.question)
        question.text = reading.text
        // A pane with no reported question still gets a card — the status said it was blocked — so the
        // block prints the far side's note in the SUPPORTING ink. The flag rides the delivery rather than
        // being re-derived from the text: an agent that happened to ask the note's exact sentence must
        // still read as having asked it.
        question.textColor = reading.isPlaceholder
            ? Slate.Native.Overlay.secondary
            : Slate.Native.Overlay.primary
    }

    /// The target pane's live inspector, or `nil` for a non-terminal or unmaterialised pane — every
    /// inspector-fed addition on this card gates on it.
    private func inspector(for target: PaneID) -> InspectorViewModel? {
        (store.handle(for: target) as? LivePaneSession)?.inspector
    }

    /// The single newest PENDING tool card, or no row at all — zero layout residue when absent. Gated on
    /// a LIVE feed: a stale feed's eternally-pending card must not masquerade as the live ask.
    private func drawPending(_ target: PaneID) {
        guard let model = inspector(for: target), model.feedState == .live,
              let card = model.toolCards.last(where: { $0.status == .pending })
        else {
            pendingRow.isHidden = true
            pendingFullRow.isHidden = true
            return
        }
        // A hard cut between the two, no chevron and no animation: the collapsed line and the full input
        // are the same fact at two lengths, and a disclosure arrow on a one-line summary is chrome.
        pendingRow.isHidden = expanded
        pendingFullRow.isHidden = !expanded
        pendingFull.text = card.inputDisplay
        // Two-tone: the tool NAME is a label and steps back, the summarised input is the thing to read.
        // WHERE that split falls is ``PendingToolSummary``'s — the same formatter the header scent and
        // the sidebar tooltip read.
        let line = PendingToolSummary.line(card: card)
        let face = UIFont.monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
        let marked = NSMutableAttributedString(
            string: line.name + ": ",
            attributes: [.font: face, .foregroundColor: Slate.Native.Overlay.secondary],
        )
        marked.append(NSAttributedString(
            string: line.summary,
            attributes: [.font: face, .foregroundColor: Slate.Native.Overlay.primary],
        ))
        pendingLine.attributedText = marked
        pending.accessibilityLabel = "\(line.name): \(line.summary)"
    }

    private func drawRecent(_ content: PeekContent) {
        recentBlock.isHidden = content.recent.isEmpty
        // The lines are REBUILT rather than reused: there are at most a handful, they carry no identity,
        // and a stack of labels has no recycling to preserve.
        for view in recentLines.arrangedSubviews {
            recentLines.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for text in content.recent {
            let label = UILabel()
            label.text = text
            label.font = .monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
            label.textColor = Slate.Native.Overlay.secondary
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            recentLines.addArrangedSubview(label)
        }
    }

    // MARK: - The disclosure

    @objc
    private func expand() {
        guard !expanded else { return }
        expanded = true
        draw()
    }

    @objc
    private func collapse() {
        guard expanded else { return }
        expanded = false
        draw()
    }

    // MARK: - Replying

    /// The ↩ / send-button path: format through the pure ``PeekReplyFormatter`` — a leading `!` strips to
    /// a shell line, empty or whitespace answers `nil` and nothing is sent — then deliver. The ADVANCE is
    /// not this card's to make: the coordinator excludes the answered pane and the follow re-resolves.
    @objc
    private func submit() {
        guard let target, let text = PeekReplyFormatter.reply(for: field.text ?? "") else { return }
        overlay.deliverPeekReply(text, to: target)
        clear()
    }

    private func clear() {
        field.text = ""
        send.isEnabled = false
    }

    @objc
    private func edited() {
        // Refusing and dimming are one act — the prominent button goes withheld rather than silently
        // eating the tap, which is ``Slate/Opacity/withheld``'s own rule spent by `UIButton`'s
        // configuration this time.
        send.isEnabled = !(field.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// ⚠️ THE QUICK ANSWER IS INTERCEPTED BEFORE THE FIELD APPLIES THE EDIT — see the file header. A bare
    /// 1–9 into an EMPTY field is "pick option N" and is declined so the digit never lands; a digit typed
    /// into a field with anything in it is a digit. A paste of "1" is a one-character replacement too and
    /// is deliberately included: it is the same intent by another route.
    func textField(
        _ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String,
    ) -> Bool {
        guard let target, (field.text ?? "").isEmpty, range.location == 0,
              string.count == 1, let digit = string.first?.wholeNumberValue,
              let text = PeekReplyFormatter.quickAnswer(digit)
        else { return true }
        overlay.deliverPeekReply(text, to: target)
        clear()
        return false
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        submit()
        // Keep the responder: the card advances to the next pane and the typing must keep landing.
        return false
    }

    // MARK: - The keyboard

    /// Esc only. Every other key on this card belongs to the field.
    ///
    /// ⚠️ IT HANGS ON THE CARD, not on the field: `keyCommands` are dispatched from the FIRST RESPONDER
    /// upwards, and the responder here is the reply field, so a command declared anywhere but on an
    /// ancestor of it is never reached.
    override var keyCommands: [UIKeyCommand]? {
        [.slateCancel(action: #selector(cancel))]
    }

    @objc
    private func cancel() { overlay.closePeekReply() }
}
#endif
