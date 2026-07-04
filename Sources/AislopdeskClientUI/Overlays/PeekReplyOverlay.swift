// PeekReplyOverlay — the "Peek & Reply" card (P4 / E13 WI-8, ⌘⌥J), NATIVE SwiftUI. Everything outside the
// workspace + panes is native chrome, so this is a native `.sheet` body (native title / status / `Divider` /
// `TextField` / prominent send button) — NOT the old bespoke `Slate.Surface.face` panel. It targets the
// OLDEST pane needing attention (`WorkspaceStore.peekReplyTargetPane`), shows that pane's cheap headless
// `PeekContent` (title + the agent's blocking question + a few recent command-block lines), and offers a
// reply field — so the user can ANSWER a blocked agent INLINE without a full tab/context switch.
//
// **Observe + reply, NEVER an approval gate** (E13 binding directive 2): the agent is never paused pending an
// aislopdesk confirmation. On submit the typed line is formatted by the pure `PeekReplyFormatter` (plain /
// `!`-shell / digit), which appends the single trailing newline, and sent VERBATIM down the pane's PTY
// (`OverlayCoordinator.deliverPeekReply` → `WorkspaceStore.sendPeekReply`) — NEVER through `SendKeysParser`.
// A bare 1–9 digit while the field is empty is the quick-answer shortcut (pick option N of a numbered prompt).
// After each reply the card ADVANCES to the next pane needing attention (excluding the just-answered one).
//
// SEAM discipline: every stateful decision (target resolution, advance, close) lives on the
// `OverlayCoordinator` (the single `@Observable` reducer, headlessly tested); this view is a thin renderer +
// the field's local text. Presented as a real sheet by ``OverlayHostView``.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
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
            if !content.recent.isEmpty { recentBlock(content) }
            Divider()
            replyBar(target: target)
        }
    }

    // MARK: - Header (the target pane + its blocking status)

    private func header(target: PaneID, content: PeekContent) -> some View {
        let status = store.agentStatus(for: target)
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
                Text(StatusPresentation.agentLabel(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("Peek & Reply")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
    /// is cleared for the next pane.
    private func submit(target: PaneID) {
        guard let text = PeekReplyFormatter.reply(for: field) else { return }
        coordinator.deliverPeekReply(text, to: target)
        field = ""
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
        return .handled
    }
}
#endif
