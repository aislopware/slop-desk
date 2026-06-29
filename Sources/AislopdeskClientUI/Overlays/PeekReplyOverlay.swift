// PeekReplyOverlay — the floating "Peek & Reply" card (P4 / E13 WI-8, otty ⌘⌥J), the VIEW over the existing
// `PeekReply` domain. It targets the OLDEST pane needing attention (`WorkspaceStore.peekReplyTargetPane`),
// shows that pane's cheap headless `PeekContent` (its title + the agent's blocking question + a few recent
// command-block lines), and offers a reply field — so the user can ANSWER a blocked agent INLINE without a
// full tab/context switch, even reaching a pane in a BACKGROUND tab.
//
// **Observe + reply, NEVER an approval gate** (E13 binding directive 2): the agent is never paused pending an
// aislopdesk confirmation; this card simply lets the human reach the agent WHEN THEY choose. On submit the
// typed line is formatted by the pure `PeekReplyFormatter` (plain / `!`-shell / digit), which appends the
// single trailing newline, and sent VERBATIM down the pane's PTY (`OverlayCoordinator.deliverPeekReply` →
// `WorkspaceStore.sendPeekReply`) — NEVER through `SendKeysParser`. A bare 1–9 digit while the field is empty
// is the quick-answer shortcut (pick option N of a numbered prompt) via `PeekReplyFormatter.quickAnswer`.
// After each reply the card ADVANCES to the next pane needing attention (excluding the just-answered one) and
// closes when none is left.
//
// SEAM discipline: every stateful decision (target resolution, advance, close) lives on the
// `OverlayCoordinator` (the single `@Observable` reducer, headlessly tested); this view is a thin renderer +
// the field's local text. The scrim + centering + fade are added by `OverlayHostView`; PeekReplyOverlay IS
// the panel. `Otty.*` tokens ONLY (raw font/colour/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SFSafeSymbols
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

    private let panelWidth: CGFloat = 460
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
        .frame(width: panelWidth)
        .background(Otty.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard)
                .stroke(Otty.Line.card, lineWidth: Otty.Metric.hairline),
        )
        .shadow(color: Otty.State.shadow, radius: 30, x: 0, y: 12)
        #if os(macOS)
            .onExitCommand { coordinator.closePeekReply() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                coordinator.closePeekReply()
                return .handled
            }
        #endif
    }

    // MARK: - Panel

    private func panel(target: PaneID, content: PeekContent) -> some View {
        VStack(spacing: 0) {
            header(target: target, content: content)
            divider
            questionBlock(content)
            if !content.recent.isEmpty { recentBlock(content) }
            divider
            replyBar(target: target)
            footerBar
        }
    }

    // MARK: - Header (the target pane + its blocking status)

    private func header(target: PaneID, content: PeekContent) -> some View {
        let status = store.agentStatus(for: target)
        return HStack(spacing: Otty.Metric.space2) {
            if let symbol = StatusPresentation.agentSymbol(status) {
                Image(systemName: symbol)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(StatusPresentation.agentTint(status))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.system(size: Otty.Typeface.body, weight: .semibold))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(StatusPresentation.agentLabel(status))
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
            }
            Spacer(minLength: Otty.Metric.space2)
            Text("Peek & Reply")
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Otty.State.header)
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
    }

    // MARK: - Question (the host type-27 blocking prompt, or a generic note)

    private func questionBlock(_ content: PeekContent) -> some View {
        Text(content.question ?? "The agent is waiting for your input.")
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(content.question == nil ? Otty.Text.secondary : Otty.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Otty.Metric.space4)
            .padding(.vertical, Otty.Metric.space3)
    }

    // MARK: - Recent output (the cheap block-mirror tail)

    private func recentBlock(_ content: PeekContent) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Text("RECENT")
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Otty.State.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(content.recent.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: Otty.Typeface.footnote, design: .monospaced))
                            .foregroundStyle(Otty.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: recentMaxHeight)
        }
        .padding(.horizontal, Otty.Metric.space4)
        .padding(.bottom, Otty.Metric.space3)
    }

    // MARK: - Reply bar

    private func replyBar(target: PaneID) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemSymbol: .arrowshapeTurnUpLeft)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            TextField("Reply…", text: $field)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent)
                .focused($replyFocused)
                .onSubmit { submit(target: target) }
                // The empty-field digit quick-answer is intercepted BEFORE the field inserts the character
                // (attached to the field so it pre-empts text editing): a bare 1–9 with the field empty fires
                // `PeekReplyFormatter.quickAnswer`. Everything else is `.ignored` so normal typing reaches the
                // field, and `↩` stays the field's native `.onSubmit` (so it never double-fires).
                .onKeyPress(phases: .down) { press in handleKey(press, target: target) }
            Button { submit(target: target) } label: {
                Image(systemSymbol: .paperplaneFill)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(field.trimmingCharacters(in: .whitespaces).isEmpty
                        ? Otty.Text.tertiary : Otty.State.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(field.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send reply")
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
        .onAppear {
            // A `@FocusState` set the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / Open-Quickly field idiom).
            DispatchQueue.main.async { replyFocused = true }
        }
    }

    // MARK: - Footer hints

    private var footerBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            footerHint("Send", glyph: "↩")
            footerHint("Quick answer", glyph: "1–9")
            Spacer(minLength: Otty.Metric.space2)
            footerHint("Close", glyph: "Esc")
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 34)
    }

    private func footerHint(_ label: String, glyph: String) -> some View {
        HStack(spacing: Otty.Metric.space1) {
            Text(label)
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Text.tertiary)
            Text(glyph)
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                        .fill(Otty.Surface.element),
                )
        }
    }

    // MARK: - All-caught-up fallback (race only)

    private var allCaughtUp: some View {
        VStack(spacing: Otty.Metric.space2) {
            Image(systemSymbol: .checkmarkCircle)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Status.ok)
            Text("Nothing needs your reply.")
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            Button("Done") { coordinator.closePeekReply() }
                .buttonStyle(.plain)
                .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                .foregroundStyle(Otty.State.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(Otty.Metric.space4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Otty.Line.divider)
            .frame(height: Otty.Metric.hairline)
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
