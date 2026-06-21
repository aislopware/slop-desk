#if canImport(SwiftUI)
import SwiftUI

// MARK: - PeekReplyView (the ⌘⇧J "Peek & Reply to a Blocked Pane" overlay)

/// The P4 low-friction-intervention overlay (docs ROADMAP P4): a glass card over a dimmed backdrop that
/// lets the human ANSWER a blocked agent INLINE — without a full tab/context switch — completing the
/// supervision loop P3 opened (P3 tells you WHICH pane needs you; P4 lets you reply to it from anywhere).
///
/// ### What it shows (read-only peek)
/// The target pane's name, its blocking question (the host type-27 ``WorkspaceStore`` `paneAgentLabel`),
/// and the last few command-block lines as a "recent output" tail — all cheap + client-side via
/// ``WorkspaceStore/peekContent(for:)`` (the per-pane ``TerminalBlockModel`` mirror, NOT the renderer's
/// `scrollbackTextLines()` — so it compiles + tests headlessly).
///
/// ### How it targets + advances
/// On open it resolves ``WorkspaceStore/peekReplyTargetPane(excluding:)`` — the FOCUSED pane when it is
/// itself blocked, else the oldest attention pane (needsPermission before done, oldest-first). After a
/// reply lands it advances to the NEXT needs-attention pane (EXCLUDING the just-answered one, which may
/// still report blocked until the host re-reports), or closes when none remain.
///
/// ### Conflict-safety (the §5 rule, mirrors CommandPaletteView)
/// Shown by a ⌘-prefixed chord (⌘⇧J, via the Pane-menu item — a registry chord fires ONLY via its menu
/// item), so it never shadows a terminal key. While up, the reply field owns first-responder and consumes
/// Esc / Enter / the 1–9 quick-answer digits via `.onKeyPress` so none fall through to the focused
/// terminal. The number-key quick-answers fire ONLY when the field is empty (so typing a digit into a
/// free-text reply is preserved).
///
/// ### Reply formatting (pure)
/// Enter sends ``PeekReplyFormatter/reply(for:)`` (a plain line, or a `!`-prefixed SHELL line — just bytes
/// to the same PTY, no privilege change) + newline; a quick-answer digit sends ``PeekReplyFormatter/
/// quickAnswer(_:)``. Both route through the ONE store chokepoint ``WorkspaceStore/sendPeekReply(_:to:)``
/// (→ `handle(for:)?.sendText`), so a reply reaches a pane that is NOT focused.
///
/// ### Mounting
/// `WorkspaceRootView` keeps `@State private var showPeekReply = false`, overlays this view (an empty,
/// zero-cost branch when hidden), and publishes a `peekReplyToggle` focused-scene value the Pane menu's
/// "Peek & Reply" item flips. Glass is on THIS card only — never on content (the one-surface rule).
struct PeekReplyView: View {
    let store: WorkspaceStore
    /// Drives presentation. Dismisses by setting this to `false` (Esc, backdrop tap, or send-with-no-next).
    @Binding var isPresented: Bool

    /// The pane currently being peeked/answered. Resolved on open + on each advance; `nil` ⇒ nothing needs
    /// attention (the card shows the empty state, or — if a focused pane exists — a read-only peek of it).
    @State private var target: PaneID?
    /// The reply field text.
    @State private var field: String = ""
    /// A transient "sent" confirmation shown briefly after a reply lands.
    @State private var sentConfirmation = false
    /// The panes already answered THIS session — excluded from the immediate advance so ⌘⇧J does not
    /// re-target a pane whose host has not yet re-reported its (now-cleared) blocked state.
    @State private var answered: Set<PaneID> = []
    /// First-responder for the reply field so the overlay owns the keyboard the instant it appears (and so
    /// the local Esc / Enter / digit handlers receive their presses).
    @FocusState private var replyFocused: Bool
    /// Reduce-Motion gate for the "sent" flash appear/revert (read from the instance methods below).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isPresented {
            ZStack {
                backdrop
                panel
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    /// The peek content for the current target, resolved ONCE per body evaluation (not per subview) so the
    /// per-pane ``TerminalBlockModel`` recent-lines formatting does not re-run on every keystroke into the
    /// reply field. `nil` when nothing needs attention (the empty/read-only state).
    private var content: PeekContent? {
        target.map { store.peekContent(for: $0) }
    }

    // MARK: Backdrop (dim + tap-to-dismiss)

    private var backdrop: some View {
        Rectangle()
            .fill(DSColor.scrim)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
    }

    // MARK: Panel (the floating card)

    private var panel: some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing5) {
            header
            Divider()
            peekBody
            replyField
            footer
        }
        .padding(UIMetrics.spacing7)
        .frame(maxWidth: UIMetrics.scaled(520))
        // L4 overlay: glass on the transient overlay (the allowed glass case — never on content/terminal
        // panes) + the inner top-edge highlight + the ONE tokenized overlay shadow (unified across the
        // floating layer in P4).
        .glassedSurface(corner: DSRadius.overlay)
        .overlay(alignment: .top) { DSElevation.innerTopHighlight() }
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.overlay, style: .continuous))
        .dsShadow(DSElevation.shadowOverlay)
        .padding(.horizontal, UIMetrics.spacing9)
        // Sit the card near the top third (Spotlight/palette placement, not dead-centre).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, UIMetrics.scaled(80))
        .onAppear { resolveTargetOnOpen() }
    }

    // MARK: Header (icon + pane name + status)

    private var header: some View {
        HStack(spacing: UIMetrics.spacing4) {
            // Red only when a genuinely-blocked target exists; the calm empty/read-only state is secondary
            // (a red alarm tint over "Nothing needs attention" would be a contradictory signal).
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: UIMetrics.iconLG))
                .foregroundStyle(
                    target == nil
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(AislopdeskTheme.statusRed),
                )
            VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                Text(content?.title ?? "Peek & Reply")
                    .font(.system(size: UIMetrics.fontHeadline, weight: .semibold))
                    .lineLimit(1)
                Text(target == nil ? "Nothing needs attention" : "Reply to this blocked pane")
                    .font(.system(size: UIMetrics.fontCaption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Peek body (question + recent output, read-only)

    private var peekBody: some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing4) {
            if let question = content?.question, !question.isEmpty {
                Text(question)
                    .font(.system(size: UIMetrics.fontBody, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIMetrics.spacing4)
                    .background(
                        RoundedRectangle(cornerRadius: UIMetrics.radiusMD, style: .continuous)
                            .fill(AislopdeskTheme.statusRed.opacity(0.12)),
                    )
            }
            recentOutput(content?.recent ?? [])
        }
    }

    private func recentOutput(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing2) {
            Text("Recent")
                .font(.system(size: UIMetrics.fontXS, weight: .medium))
                .foregroundStyle(.secondary)
            if lines.isEmpty {
                Text("No recent output")
                    .font(.system(size: UIMetrics.fontCaption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: UIMetrics.fontCaption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(UIMetrics.spacing4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD, style: .continuous)
                .fill(Color.primary.opacity(0.05)),
        )
    }

    // MARK: Reply field (owns the keyboard + Esc / Enter / digit handlers)

    private var replyField: some View {
        HStack(spacing: UIMetrics.spacing3) {
            Image(systemName: "arrow.turn.down.left")
                .font(.system(size: UIMetrics.iconSM))
                .foregroundStyle(.secondary)
            TextField(replyPlaceholder, text: $field)
                .textFieldStyle(.plain)
                .font(.system(size: UIMetrics.fontBody, design: .monospaced))
                .focused($replyFocused)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #endif
                .onSubmit(sendReply)
                .onKeyPress(.return) { sendReply()
                    return .handled
                }
                .onKeyPress(.escape) { dismiss()
                    return .handled
                }
                // Quick-answer digits 1–9 fire ONLY when the field is empty (so a digit typed into a
                // free-text reply is preserved). Consumed here so they never reach the focused terminal.
                .onKeyPress(characters: Self.digitCharacters) { press in
                    guard field.isEmpty, let n = press.characters.first.flatMap({ Int(String($0)) }) else {
                        return .ignored
                    }
                    sendQuickAnswer(n)
                    return .handled
                }
        }
        .padding(.horizontal, UIMetrics.spacing4)
        .padding(.vertical, UIMetrics.spacing3)
        .background(
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD, style: .continuous)
                .fill(Color.primary.opacity(0.06)),
        )
        .disabled(target == nil)
    }

    // MARK: Footer (hint + sent confirmation)

    private var footer: some View {
        HStack(spacing: UIMetrics.spacing3) {
            if sentConfirmation {
                Label("Sent", systemImage: "checkmark.circle.fill")
                    .font(.system(size: UIMetrics.fontCaption))
                    .foregroundStyle(AislopdeskTheme.statusGreen)
                    .transition(.opacity)
            } else {
                Text("⏎ send · 1–9 quick answer · ! shell · esc close")
                    .font(.system(size: UIMetrics.fontCaption))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Placeholder / digit set

    private var replyPlaceholder: String {
        target == nil ? "Nothing to reply to" : "Type a reply, a number, or !shell-command"
    }

    /// The 1–9 digit characters the quick-answer handler claims (0 is intentionally excluded — numbered
    /// prompts start at 1).
    private static let digitCharacters = CharacterSet(charactersIn: "123456789")

    // MARK: Actions

    /// Resolves the initial target on open. When nothing needs attention the card shows the empty state and
    /// the field is disabled (a read-only no-op peek). Focuses the reply field for keyboard ownership.
    private func resolveTargetOnOpen() {
        field = ""
        answered = []
        sentConfirmation = false
        target = store.peekReplyTargetPane()
        replyFocused = true
    }

    /// Sends the free-text / bang-shell reply (Enter). No-op for an empty field or no target. After a
    /// successful send it confirms + advances to the next needs-attention pane (or closes).
    private func sendReply() {
        guard let id = target, let text = PeekReplyFormatter.reply(for: field) else { return }
        store.sendPeekReply(text, to: id)
        field = ""
        confirmAndAdvance(answered: id)
    }

    /// Sends a quick-answer digit (1–9) into the target pane, then confirms + advances.
    private func sendQuickAnswer(_ n: Int) {
        guard let id = target, let text = PeekReplyFormatter.quickAnswer(n) else { return }
        store.sendPeekReply(text, to: id)
        confirmAndAdvance(answered: id)
    }

    /// Flashes the "sent" confirmation, records `answered`, and advances to the next needs-attention pane
    /// EXCLUDING every pane answered this session (so the same pane is not re-targeted before the host
    /// re-reports). Closes when none remain.
    ///
    /// When advancing to a NEXT pane the confirmation is a TRANSIENT flash (~1s) that reverts to the
    /// keyboard-hint line, so a stale "Sent" badge (confirming the previous pane) never lingers while you
    /// compose the next reply. On the final send the overlay closes immediately, so no revert is needed.
    private func confirmAndAdvance(answered id: PaneID) {
        answered.insert(id)
        // P5 MOTION: the "Sent" flash appears via DSMotion.appear, Reduce-Motion-gated to the crossfade.
        withAnimation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion)) { sentConfirmation = true }
        if let next = store.peekReplyTargetPane(excluding: answered) {
            target = next
            replyFocused = true
            scheduleConfirmationRevert()
        } else {
            dismiss()
        }
    }

    /// Reverts the transient "Sent" flash to the hint line after ~1s, restoring the keyboard-verb affordance
    /// for the next pane. Guarded by `isPresented` so it is a no-op if the overlay closed in the interim
    /// (capturing nothing that outlives dismiss).
    private func scheduleConfirmationRevert() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard isPresented else { return }
            // P5 MOTION: the flash reverts to the hint line via DSMotion.dismiss, Reduce-Motion-gated.
            withAnimation(DSMotion.resolve(DSMotion.dismiss, reduceMotion: reduceMotion)) { sentConfirmation = false }
        }
    }

    /// Clears state and lowers the presentation binding. Called by Esc, backdrop tap, and after a final send.
    private func dismiss() {
        replyFocused = false
        isPresented = false
        target = nil
        field = ""
        answered = []
        sentConfirmation = false
    }
}
#endif
