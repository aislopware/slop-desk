// PeekReplyOverlay — the "Peek & Reply" card (⌘⌥J), NATIVE SwiftUI. Everything outside the
// workspace + panes is native chrome, so this is a native `.sheet` body (native title / status / `Divider` /
// `TextField` / prominent send button) — NOT a bespoke `Slate.Surface.face` panel. It targets the
// OLDEST pane needing attention (`WorkspaceStore.peekReplyTargetPane`), shows that pane's cheap headless
// `PeekContent` (title + the agent's blocking question + a few recent command-block lines), and offers a
// reply field — so the user can ANSWER a blocked agent INLINE without a full tab/context switch.
//
// **Observe + reply, NEVER an approval gate**: the agent is never paused pending an
// slopdesk confirmation. On submit the typed line is formatted by the pure `PeekReplyFormatter` (plain /
// `!`-shell / digit), which appends the single trailing newline, and sent VERBATIM down the pane's PTY
// (`OverlayCoordinator.deliverPeekReply` → `WorkspaceStore.sendPeekReply`) — NEVER through `SendKeysParser`.
// A bare 1–9 digit while the field is empty is the quick-answer shortcut (pick option N of a numbered prompt).
// After each reply the card ADVANCES to the next pane needing attention (excluding the just-answered one).
//
// SEAM discipline: every stateful decision (target resolution, advance, close) lives on the
// `OverlayCoordinator` (the single `@Observable` reducer, headlessly tested); this view is a thin renderer +
// the field's local text. Presented as a real sheet by ``OverlayHostView``.

#if canImport(SwiftUI)
import SlopDeskAgentDetect
import SlopDeskInspector
import SlopDeskWorkspaceCore
import SwiftUI

struct PeekReplyOverlay: View {
    /// The live store — the source of the target pane, its ``PeekContent`` (title / question / recent lines),
    /// and the rolled-up per-pane agent status the header badge reflects.
    let store: WorkspaceStore
    /// The single overlay reducer — owns the target resolution + advance-to-next + close. `@Observable`, so
    /// reading ``OverlayCoordinator/peekReplyExcluding`` (via ``OverlayCoordinator/peekReplyTarget()``) in
    /// `body` re-resolves the target after each reply.
    let coordinator: OverlayCoordinator

    /// The reply field text. A bare 1–9 digit while this is empty is the quick-answer shortcut; otherwise the
    /// trimmed line + a newline (a leading `!` strips to a shell line) is sent on submit.
    @State private var field = ""
    /// Pre-focuses the reply field on appear so typing (and the empty-field digit shortcut) reaches it.
    @FocusState private var replyFocused: Bool

    /// Whether the pending-tool-call block is showing its full scrollable input instead of the
    /// collapsed one-liner. Reset to `false` on every advance (``submit(target:)`` / the quick-answer digit
    /// path) — a fresh target's card starts collapsed, never inheriting the previous pane's disclosure.
    @State private var pendingToolExpanded = false

    private let recentMaxHeight: CGFloat = 132

    var body: some View {
        Group {
            if let target = coordinator.peekReplyTarget() {
                panel(target: target, content: store.peekContent(for: target))
            } else {
                // Robustness only: the open-gate requires a target and the advance closes when none is left,
                // so this is a near-impossible race (the host cleared the status mid-present). Show an honest
                // "all caught up" card rather than mutating state during `body`.
                allCaughtUp
            }
        }
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    // MARK: - Panel

    private func panel(target: PaneID, content: PeekContent) -> some View {
        VStack(spacing: 0) {
            header(target: target, content: content)
            Divider()
            questionBlock(content)
            pendingToolBlock(target: target)
            if !content.recent.isEmpty { recentBlock(content) }
            Divider()
            replyBar(target: target)
        }
    }

    // MARK: - Header (the target pane + its blocking status)

    private func header(target: PaneID, content: PeekContent) -> some View {
        let status = store.agentStatus(for: target)
        let label = StatusPresentation.agentLabel(status)
        // The todo-scent suffix: only while a `.live` inspector reports an `.inProgress`
        // todo, so an idle / non-Claude / dead-feed pane's caption is byte-identical to today.
        let scent = liveInspector(for: target).flatMap { vm in
            vm.feedState == .live ? PendingToolSummary.scent(todos: vm.todos) : nil
        }
        let caption = scent.map { "\(label) · \($0)" } ?? label
        return HStack(spacing: 8) {
            if let symbol = StatusPresentation.agentSymbol(status) {
                Image(systemName: symbol)
                    .foregroundStyle(StatusPresentation.agentTint(status))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Truncation order: the suffix puts activeForm LAST, so a tail
                    // truncation eats the prose first, the "i/n" count second, the status label never.
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // The queue position REPLACES the static caption once a real queue (total >= 2)
            // exists — a hard cut on the queue edge, never both at once.
            if let position = queuePosition {
                Text("\(position.position) of \(position.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
                    .lineLimit(1)
            } else {
                Text("Peek & Reply")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The "N of M" triage-queue position, or `nil` for a single-target session (a queue of
    /// one is not a queue — the calm static "Peek & Reply" caption stays). Derives from the SAME
    /// exclusion set + attention predicate the advance chain itself uses
    /// (``PeekReplyTarget/queuePosition(status:panes:excluding:)``), so the counter and the chain can
    /// never disagree.
    private var queuePosition: (position: Int, total: Int)? {
        PeekReplyTarget.queuePosition(
            status: { store.agentStatus(for: $0) },
            panes: store.tree.allPaneIDs(),
            excluding: coordinator.peekReplyExcluding,
        )
    }

    // MARK: - Question (the host type-27 blocking prompt, or a generic note)

    private func questionBlock(_ content: PeekContent) -> some View {
        Text(content.question ?? "The agent is waiting for your input.")
            .font(.body)
            .foregroundStyle(content.question == nil ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    // MARK: - Pending tool call (the exact call the question above is asking about)

    /// The target pane's live inspector (``LivePaneSession/inspector``), or `nil` for a non-terminal /
    /// unmaterialized pane — every inspector-fed addition here gates on this.
    private func liveInspector(for target: PaneID) -> InspectorViewModel? {
        (store.handle(for: target) as? LivePaneSession)?.inspector
    }

    /// The single newest `.pending` ``ToolCard`` block, or nothing at all — zero layout residue when
    /// absent. Gated on ``InspectorViewModel/feedState`` being `.live`: a STALE feed's eternally-pending
    /// card must not masquerade as the live ask (fully-formed-or-absent, never greyed as "the past").
    private func pendingToolBlock(target: PaneID) -> some View {
        Group {
            if let vm = liveInspector(for: target), vm.feedState == .live,
               let card = vm.toolCards.last(where: { $0.status == .pending })
            {
                pendingToolRow(card)
            }
        }
    }

    /// The collapsed one-line `"<name>: <summary>"` row (via the shared ``PendingToolSummary`` — the
    /// SAME formatter the header scent + the sidebar tooltip use), rendered as a plain click-to-expand
    /// button. Expanded swaps it — hard cut, no chevron, no animation — for a scroll capped at
    /// ``recentMaxHeight`` showing the full input, selectable. No background plate, border, icon, or
    /// status colour: the header's red triangle already says "blocked".
    @ViewBuilder
    private func pendingToolRow(_ card: ToolCard) -> some View {
        if pendingToolExpanded {
            ScrollView {
                Text(card.input.displayString)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: recentMaxHeight)
            .contentShape(Rectangle())
            .onTapGesture { pendingToolExpanded = false }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        } else {
            let line = PendingToolSummary.line(name: card.name, input: card.input)
            Button {
                pendingToolExpanded = true
            } label: {
                Text(attributedLine(line))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Show full input")
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    /// Two-tone rendering of a ``PendingToolLine``: the tool name `.secondary` (a label), the summarized
    /// input `.primary` (the thing to read) — one `AttributedString` rather than `Text`-concatenation
    /// (deprecated in favour of exactly this on newer SDKs).
    private func attributedLine(_ line: PendingToolLine) -> AttributedString {
        var name = AttributedString(line.name + ": ")
        name.foregroundColor = .secondary
        var summary = AttributedString(line.summary)
        summary.foregroundColor = .primary
        return name + summary
    }

    // MARK: - Recent output (the cheap block-mirror tail)

    private func recentBlock(_ content: PeekContent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(content.recent.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: recentMaxHeight)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Reply bar

    private func replyBar(target: PaneID) -> some View {
        HStack(spacing: 8) {
            TextField("Reply…", text: $field)
                .textFieldStyle(.roundedBorder)
                .focused($replyFocused)
                .onSubmit { submit(target: target) }
                // The empty-field digit quick-answer is intercepted BEFORE the field inserts the character:
                // a bare 1–9 with the field empty fires `PeekReplyFormatter.quickAnswer`. Everything else is
                // `.ignored` so normal typing reaches the field, and `↩` stays the field's native `.onSubmit`.
                .onKeyPress(phases: .down) { press in handleKey(press, target: target) }
            Button {
                submit(target: target)
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(field.trimmingCharacters(in: .whitespaces).isEmpty)
            // Enter submits via the field's `.onSubmit` (below); no `.keyboardShortcut(.return)` here or a
            // single Enter would deliver the reply TWICE (button action + onSubmit).
            .accessibilityLabel("Send reply")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .onAppear {
            // A `@FocusState` set the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / Open-Quickly field idiom).
            DispatchQueue.main.async { replyFocused = true }
        }
    }

    // MARK: - All-caught-up fallback (race only)

    private var allCaughtUp: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Nothing needs your reply.")
                .foregroundStyle(.secondary)
            Button("Done") { coordinator.closePeekReply() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    /// Submit the typed reply (the `↩` / send-button path): format via the pure ``PeekReplyFormatter`` (a
    /// leading `!` strips to a shell line; empty / whitespace ⇒ nil ⇒ no-op) then deliver + advance. The field
    /// is cleared, and the pending-tool disclosure collapses, for the next pane.
    private func submit(target: PaneID) {
        guard let text = PeekReplyFormatter.reply(for: field) else { return }
        coordinator.deliverPeekReply(text, to: target)
        field = ""
        pendingToolExpanded = false
    }

    /// Intercept a bare 1–9 quick-answer digit while the field is empty (the "pick option N" shortcut). Any
    /// modifier (a chord) or a non-empty field ⇒ `.ignored` so the field handles normal typing.
    private func handleKey(_ press: KeyPress, target: PaneID) -> KeyPress.Result {
        // A chord (⌘/⌥/⌃ + key) is never a quick-answer — let it pass so it can't be mistaken for a digit.
        let chordModifiers: EventModifiers = [.command, .option, .control]
        guard field.isEmpty,
              press.modifiers.isDisjoint(with: chordModifiers),
              let digit = press.key.character.wholeNumberValue,
              let text = PeekReplyFormatter.quickAnswer(digit)
        else { return .ignored }
        coordinator.deliverPeekReply(text, to: target)
        field = ""
        pendingToolExpanded = false
        return .handled
    }
}
#endif
