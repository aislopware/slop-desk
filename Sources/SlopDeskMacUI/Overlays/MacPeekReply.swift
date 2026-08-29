// MacPeekReply — the ⌘⌥J Peek & Reply card, in AppKit.
//
// The fifth surface off the shared SwiftUI floor (docs/56 stage D) and the second modal one. The
// palette settled the shape of a card you type into and steer with the keyboard; what this one adds
// is that its CONTENT is live and its target MOVES — a reply is delivered, the queue advances, and
// the whole card is re-cut for the next blocked pane without the panel ever going away.
//
// Three things follow from that, and they are what this file is:
//
//   1. IT REDRAWS OFF OBSERVATION. The target, the pane's `PeekContent`, its agent status and its
//      inspector's pending call are all read inside an ``ObservationFollow``, so the card follows
//      the store rather than the card's own events. That is not an optimisation here — the advance
//      is the coordinator's, and a card that only redrew on its own keystrokes would keep showing
//      the pane it just answered.
//   2. A NEW TARGET CROSSFADES. Without the beat, question / recent / pending-tool all mutate in one
//      frame and it reads as the SAME pane changing rather than as the next one arriving. The phone
//      gets this from `.id(target)` + a transition; here it is the family's own short curve on the
//      card's alpha, fired on the target EDGE and nowhere else.
//   3. THE FIELD OWNS THE KEYBOARD, and one key is taken off it. A bare 1–9 while the field is empty
//      is the quick-answer shortcut ("pick option N"), which has to be read BEFORE the field inserts
//      the character — so it is answered in `performKeyEquivalent(with:)`, the door every key-down
//      passes through before the responder chain. Everything else is the field's: ↩ submits through
//      `insertNewline:` and Esc closes through `cancelOperation:`, both as editing commands.
//
// **Observe + reply, NEVER an approval gate.** Nothing here pauses an agent pending a slopdesk
// confirmation. The typed line is formatted by ``PeekReplyFormatter`` and sent VERBATIM down the
// pane's PTY, never through `SendKeysParser`.
//
// What it does NOT own is what the card SAYS: ``PeekReplyPresentation`` decides the caption, the
// counter, the stand-in note and the zero-state line, ``PeekReplyTarget`` decides which pane and
// where it sits in the queue, and ``PendingToolSummary`` collapses the pending call. Every one of
// them is shared with the phone's ``PhonePeekReplyCardView``.

import AppKit
import SlopDeskAgentDetect // ClaudeStatus — the header's own reading
import SlopDeskClientCore
import SlopDeskInspector
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The card

@MainActor
final class MacPeekReplyView: NSView, NSTextFieldDelegate {
    private let store: WorkspaceStore
    private let coordinator: OverlayCoordinator

    /// The card's blocks, stacked. Hidden ones leave the layout entirely, which is what lets a pane
    /// with no pending call and no recent output produce a genuinely shorter card rather than one
    /// with two empty bands in it.
    private let column = NSStackView()
    private let header = MacPeekHeaderView()
    private let question = NSTextField(labelWithString: "")
    private let pendingTool = MacPeekPendingToolView()
    private let recent = MacPeekRecentView()
    private let caughtUp = MacPeekCaughtUpView()
    private let topRule = MacCardRuleView()
    private let bottomRule = MacCardRuleView()
    private let field = NSTextField()
    private let send = NSButton()
    /// The question's padded band and the reply bar, kept because the zero-state card drops BOTH —
    /// hiding the field alone would leave its band standing empty at the card's foot.
    private let questionBlock = NSView()
    private let replyBar = NSStackView()

    /// The pane the card is currently cut for, so a change of target can be told from a change of
    /// that target's content — only the former crossfades.
    private var target: PaneID?
    /// Whether the pending-tool block is showing its full input instead of the collapsed line. Reset
    /// on every advance: a fresh target's card starts collapsed, never inheriting the last pane's
    /// disclosure.
    private var pendingToolExpanded = false
    /// The height the card took at the last render, so the panel is only re-sized when it moved.
    private var cardHeight: Double = 0
    /// The live follow behind ``render()``, held so the next render can REPLACE it rather than stack a
    /// second one — see that method for the two doors that make the replace load-bearing.
    private var renderFollow: ObservationFollow?

    /// Told the card's wanted size whenever its content changes height.
    var onResize: (NSSize) -> Void = { _ in }

    /// The width text actually wraps at: the card, less the one horizontal margin every block keeps.
    static let textWidth = Slate.Metric.cardFormWidth - Slate.Metric.space4 * 2

    init(store: WorkspaceStore, coordinator: OverlayCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init(frame: .zero)

        buildQuestion()
        buildReplyBar()
        buildColumn()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func buildQuestion() {
        question.lineBreakMode = .byWordWrapping
        question.maximumNumberOfLines = 0
        question.isSelectable = false
        question.font = .preferredFont(forTextStyle: .body)
        question.setContentCompressionResistancePriority(.required, for: .vertical)
        // A wrapping label has no intrinsic HEIGHT until it knows the width it wraps at, and the
        // card is measured by `fittingSize` before it is ever laid out at that width — so the width
        // is told to it rather than discovered. It is a constant here because the card's own width
        // is (``Slate/Metric/cardFormWidth``, fixed for the same reason the palette's is).
        question.preferredMaxLayoutWidth = Self.textWidth
    }

    private func buildReplyBar() {
        // A REAL macOS field, at the system's size. A hand-drawn plate was tried on the sibling
        // surfaces and read as cramped beside a stock button: the card is ours, the controls in it
        // are the system's.
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        field.placeholderString = PeekReplyCopy.replyPrompt
        field.delegate = self

        send.image = NSImage(
            systemSymbolName: "paperplane.fill", accessibilityDescription: PeekReplyCopy.sendReply,
        )
        send.imagePosition = .imageOnly
        send.bezelStyle = .push
        send.controlSize = .large
        // The prominent button, spelled the way AppKit spells it: the accent on the bezel and white
        // on the glyph. ⚠️ NO key equivalent — ↩ already submits through the field's `insertNewline:`,
        // and a default button would deliver every reply TWICE.
        send.bezelColor = .controlAccentColor
        send.contentTintColor = .white
        send.target = self
        send.action = #selector(submit)
        send.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func buildColumn() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        for control in [field, send] as [NSView] { replyBar.addView(control, in: .leading) }
        replyBar.orientation = .horizontal
        replyBar.alignment = .centerY
        replyBar.spacing = Slate.Metric.space2
        replyBar.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space3, left: Slate.Metric.space4,
            bottom: Slate.Metric.space3, right: Slate.Metric.space4,
        )

        questionBlock.addSubview(question)
        question.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            question.leadingAnchor.constraint(
                equalTo: questionBlock.leadingAnchor, constant: Slate.Metric.space4,
            ),
            question.trailingAnchor.constraint(
                equalTo: questionBlock.trailingAnchor, constant: -Slate.Metric.space4,
            ),
            question.topAnchor.constraint(
                equalTo: questionBlock.topAnchor, constant: Slate.Metric.space3,
            ),
            question.bottomAnchor.constraint(
                equalTo: questionBlock.bottomAnchor, constant: -Slate.Metric.space3,
            ),
        ])

        caughtUp.isHidden = true
        let blocks: [NSView] = [
            header, topRule, questionBlock, pendingTool, recent, caughtUp, bottomRule, replyBar,
        ]
        for block in blocks {
            column.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        for rule in [topRule, bottomRule] {
            rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline).isActive = true
        }
        NSLayoutConstraint.activate(column.slateEdges(of: self))
        pendingTool.onToggle = { [weak self] in
            guard let self else { return }
            pendingToolExpanded.toggle()
            render()
        }
    }

    // MARK: Presentation

    /// Gives the reply field the keyboard and cuts the first card. Called once the panel is on
    /// screen — a field cannot become first responder in a window that is not yet key.
    func begin() {
        window?.makeFirstResponder(field)
        render()
    }

    /// Draws the current state, and re-arms itself on everything it read.
    ///
    /// ``ObservationFollow`` keeps the beat this needs: its wake is scheduled onto the next main turn
    /// rather than run inside the change, which the card depends on because the callback fires BEFORE
    /// the value it announces is stored.
    ///
    /// `replacing:` rather than a bare arm, because this card has a SECOND door into `render()` — the
    /// pending-tool disclosure's `onToggle`. Arming is not idempotent, so without the replace every
    /// expand/collapse would leave another live follow behind and the card would redraw N times a change.
    ///
    /// The work sits inside `read` rather than in `apply`, against that type's usual shape: the tracked
    /// block IS the draw, so the transitive reads of ``draw()`` ARE the dependency set. Split the two and
    /// the set empties — the card would draw once and then follow nothing. `apply` is empty for that
    /// reason, not by omission.
    private func render() {
        renderFollow = ObservationFollow.arm(self, replacing: renderFollow) { $0.draw() } apply: { _, _ in }
    }

    private func draw() {
        let next = coordinator.peekReplyTarget()
        let arrived = next != target
        target = next
        if let next {
            drawTarget(next)
        } else {
            // Robustness only: the open-gate requires a target and the advance closes when none is
            // left, so this is a near-impossible race (the host cleared the status mid-present). An
            // honest "all caught up" card, rather than mutating state mid-draw.
            drawCaughtUp()
        }
        fitToContent()
        if arrived { crossfade() }
    }

    private func drawTarget(_ pane: PaneID) {
        caughtUp.isHidden = true
        for view in [header, topRule, questionBlock, bottomRule, replyBar] as [NSView] {
            view.isHidden = false
        }

        let content = store.peekContent(for: pane)
        let status = store.agentStatus(for: pane)
        let inspector = liveInspector(for: pane)
        // The todo scent only while a `.live` inspector reports an in-progress item — an idle,
        // non-Claude or dead-feed pane's caption stays byte-identical to the label alone.
        let scent = inspector.flatMap { vm in
            vm.feedState == .live ? PendingToolSummary.scent(todos: vm.todos) : nil
        }
        header.show(
            title: content.title,
            caption: PeekReplyPresentation.caption(status: status, scent: scent),
            counter: PeekReplyPresentation.counter(queuePosition),
            status: status,
        )

        let (text, isPlaceholder) = PeekReplyPresentation.question(content.question)
        question.stringValue = text
        question.textColor = isPlaceholder
            ? Slate.Native.Overlay.secondary : Slate.Native.Overlay.primary

        // The single newest PENDING card, or nothing at all — zero layout residue when absent, and
        // gated on a `.live` feed so a stale feed's eternally-pending card cannot masquerade as the
        // live ask.
        let card = inspector.flatMap { vm in
            vm.feedState == .live ? vm.toolCards.last(where: { $0.status == .pending }) : nil
        }
        pendingTool.show(card, expanded: pendingToolExpanded)
        recent.show(content.recent)
        send.isEnabled = PeekReplyFormatter.reply(for: field.stringValue) != nil
    }

    private func drawCaughtUp() {
        let blocks: [NSView] = [
            header, topRule, questionBlock, pendingTool, recent, bottomRule, replyBar,
        ]
        for view in blocks { view.isHidden = true }
        caughtUp.isHidden = false
        caughtUp.onDone = { [coordinator] in coordinator.closePeekReply() }
    }

    /// The target pane's live inspector, or `nil` for a non-terminal / unmaterialized pane — every
    /// inspector-fed block gates on this.
    private func liveInspector(for pane: PaneID) -> InspectorViewModel? {
        (store.handle(for: pane) as? LivePaneSession)?.inspector
    }

    /// The "N of M" triage position, from the SAME exclusion set and attention predicate the advance
    /// chain itself uses — so the counter and the chain can never disagree.
    private var queuePosition: (position: Int, total: Int)? {
        PeekReplyTarget.queuePosition(
            status: { [store] in store.agentStatus(for: $0) },
            panes: store.tree.allPaneIDs(),
            excluding: coordinator.peekReplyExcluding,
        )
    }

    /// Tells the panel the height this card's blocks want.
    private func fitToContent() {
        column.layoutSubtreeIfNeeded()
        let wanted = column.fittingSize.height
        guard wanted != cardHeight else { return }
        cardHeight = wanted
        onResize(NSSize(width: Slate.Metric.cardFormWidth, height: wanted))
    }

    /// The beat between one blocked pane and the next.
    private func crossfade() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            animator().alphaValue = 1
        }
    }

    // MARK: The keyboard

    /// The empty-field quick-answer digit, read before the field can insert it.
    ///
    /// A CHORD is never a quick answer — ⌘1 switches tabs — so any of the three modifiers passes
    /// straight through, as does every key once the field has something in it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let target, field.stringValue.isEmpty,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
              let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
              let text = PeekReplyFormatter.quickAnswer(digit)
        else { return false }
        deliver(text, to: target)
        return true
    }

    /// The button is lit by the FORMATTER's own answer rather than by a second emptiness test, so a
    /// field the formatter has nothing to send for (whitespace, a bare `!`) cannot offer a button
    /// that would no-op on the click.
    func controlTextDidChange(_: Notification) {
        send.isEnabled = PeekReplyFormatter.reply(for: field.stringValue) != nil
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
        case #selector(NSResponder.cancelOperation(_:)):
            coordinator.closePeekReply()
        default:
            return false
        }
        return true
    }

    // MARK: Actions

    /// The ↩ / send-button path: format via the pure ``PeekReplyFormatter`` (a leading `!` strips to a
    /// shell line; empty ⇒ nothing to send) then deliver and advance.
    @objc
    private func submit() {
        guard let target, let text = PeekReplyFormatter.reply(for: field.stringValue) else { return }
        deliver(text, to: target)
    }

    private func deliver(_ text: String, to pane: PaneID) {
        coordinator.deliverPeekReply(text, to: pane)
        field.stringValue = ""
        send.isEnabled = false
        // The next pane's card starts collapsed. Set BEFORE the render the advance triggers, so the
        // incoming target is never drawn holding the outgoing one's disclosure.
        pendingToolExpanded = false
    }
}

// MARK: - The header

/// The target pane, its blocking status, and where it sits in the queue.
@MainActor
final class MacPeekHeaderView: NSView {
    private let glyph = MacAgentGlyphView(frame: .zero)
    private let title = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .preferredFont(forTextStyle: .headline)
        // Middle-truncated: a pane's name is `session ▸ tab ▸ pane`, and both ends say more than
        // the middle does.
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = Slate.Native.Overlay.secondary
        // Tail-truncated, and the caption is built with the scent LAST for exactly this: a squeeze
        // eats the prose first, the count second, the status word never.
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        trailing.maximumNumberOfLines = 1
        for label in [title, caption, trailing] { label.isSelectable = false }

        let lines = NSStackView(views: [title, caption])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space3, left: Slate.Metric.space4,
            bottom: Slate.Metric.space3, right: Slate.Metric.space4,
        )
        for view in [glyph, lines] as [NSView] { row.addView(view, in: .leading) }
        row.addView(trailing, in: .trailing)
        // The name yields before the counter: "3 of 7" truncated is not a count, and a truncated
        // pane name is still the pane you recognise.
        for label in [title, caption] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(row)
        NSLayoutConstraint.activate(row.slateEdges(of: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(title name: String, caption text: String, counter: String?, status: ClaudeStatus) {
        title.stringValue = name
        caption.stringValue = text
        if let reading = AgentReadout.reading(status) {
            glyph.isHidden = false
            glyph.show(reading: reading, ink: AgentReadout.ink(status))
        } else {
            glyph.isHidden = true
        }
        // The counter REPLACES the static caption once a real queue exists — a hard cut on the queue
        // edge, never both at once.
        if let counter {
            trailing.stringValue = counter
            trailing.font = .monospacedDigitSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular,
            )
            trailing.textColor = Slate.Native.Overlay.tertiary
        } else {
            trailing.stringValue = PeekReplyPresentation.title
            trailing.font = .systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium,
            )
            trailing.textColor = Slate.Native.Overlay.secondary
        }
    }
}

// MARK: - The pending call

/// The exact tool call the question above is asking about: one collapsed line, or — clicked — its
/// whole input in a scroll well.
///
/// No plate, no border, no icon, no status colour. The header's own reading already says "blocked",
/// and a second frame round the thing it is blocked ON would say it twice.
@MainActor
final class MacPeekPendingToolView: NSView {
    /// Fired by a click on the collapsed line, and by a click in the expanded well's own margin —
    /// never by a click on the expanded TEXT, which is a selection.
    var onToggle: () -> Void = {}

    private let line = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let full = NSTextField(wrappingLabelWithString: "")
    /// The two bottom edges, activated one at a time: whichever body is showing is the one that
    /// sets this block's height. And the well's own height, which is its CONTENT's, capped — a
    /// scroll view has no intrinsic size of its own, so without this the block would measure zero
    /// and the card would come up with the input missing.
    private var lineBottom: NSLayoutConstraint?
    private var scrollBottom: NSLayoutConstraint?
    private var scrollHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.lineBreakMode = .byTruncatingMiddle
        line.maximumNumberOfLines = 1
        line.isSelectable = false
        line.toolTip = "Show full input"

        full.isSelectable = true
        full.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        full.textColor = Slate.Native.Overlay.primary
        full.preferredMaxLayoutWidth = MacPeekReplyView.textWidth
        full.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = full
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true

        for view in [line, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight = height
        lineBottom = line.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -Slate.Metric.space3,
        )
        scrollBottom = scroll.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -Slate.Metric.space3,
        )
        NSLayoutConstraint.activate([
            height,
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            line.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            full.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ card: ToolCard?, expanded: Bool) {
        guard let card else {
            isHidden = true
            return
        }
        isHidden = false
        line.isHidden = expanded
        scroll.isHidden = !expanded
        lineBottom?.isActive = !expanded
        scrollBottom?.isActive = expanded
        if expanded {
            full.stringValue = card.inputDisplay
            full.layoutSubtreeIfNeeded()
            scrollHeight?.constant = Swift.min(
                full.fittingSize.height, PeekReplyMetrics.scrollMaxHeight,
            )
        } else {
            scrollHeight?.constant = 0
            line.attributedStringValue = Self.twoTone(
                PendingToolSummary.line(card: card),
            )
        }
    }

    /// The tool NAME is a label and the summarized input is the thing to read, so they take the
    /// supporting and the reading ink — one attributed string rather than two concatenated fields,
    /// which is what lets the pair truncate as one line.
    private static func twoTone(_ line: PendingToolLine) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let spliced = NSMutableAttributedString(
            string: line.name + ": ",
            attributes: [.font: font, .foregroundColor: Slate.Native.Overlay.secondary],
        )
        spliced.append(NSAttributedString(
            string: line.summary,
            attributes: [.font: font, .foregroundColor: Slate.Native.Overlay.primary],
        ))
        return spliced
    }

    override func mouseDown(with _: NSEvent) {
        onToggle()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - The recent tail

/// The cheap block-mirror tail: a caps label and a few one-line command receipts, capped and
/// scrolling past the cap.
@MainActor
final class MacPeekRecentView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let lines = NSStackView()
    private var labels: [NSTextField] = []
    /// The well's height is its CONTENT's, capped. A scroll view has no intrinsic size, so without
    /// this the tail would measure zero and the card would come up with it missing.
    private var scrollHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The caps micro-label in the instrument voice — the card NAMING a region.
        heading.attributedStringValue = macCapsString(
            PeekReplyCopy.recentHeading, color: Slate.Native.Overlay.tertiary,
        )
        heading.isSelectable = false

        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = lines
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true

        for view in [heading, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight = height
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            heading.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Slate.Metric.space1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space3),
            height,
            lines.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ recent: [String]) {
        guard !recent.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        if labels.count != recent.count {
            for label in labels {
                lines.removeArrangedSubview(label)
                label.removeFromSuperview()
            }
            labels = recent.map { _ in
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                label.textColor = Slate.Native.Overlay.secondary
                label.lineBreakMode = .byTruncatingMiddle
                label.maximumNumberOfLines = 1
                label.isSelectable = false
                lines.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
                return label
            }
        }
        for (label, text) in zip(labels, recent) { label.stringValue = text }
        lines.layoutSubtreeIfNeeded()
        scrollHeight?.constant = Swift.min(
            lines.fittingSize.height, PeekReplyMetrics.scrollMaxHeight,
        )
    }
}

// MARK: - The zero state

/// The race-only card: the host cleared the last blocking status while this one was up.
@MainActor
final class MacPeekCaughtUpView: NSView {
    var onDone: () -> Void = {}

    private let done = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        mark.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .regular,
        )
        mark.contentTintColor = Slate.Native.Status.ok

        let note = NSTextField(labelWithString: PeekReplyPresentation.allCaughtUp)
        note.textColor = Slate.Native.Overlay.secondary
        note.isSelectable = false

        done.title = "Done"
        done.bezelStyle = .push
        // Esc reaches the panel's own backdrop, so this button is the POINTER's way out and does not
        // also claim the key — the card has no field to steal it from here, but the two paths must
        // not both fire.
        done.target = self
        done.action = #selector(finish)

        let stack = NSStackView(views: [mark, note, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Slate.Metric.space2
        stack.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space4, right: Slate.Metric.space4,
        )
        addSubview(stack)
        NSLayoutConstraint.activate(stack.slateEdges(of: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func finish() {
        onDone()
    }
}
