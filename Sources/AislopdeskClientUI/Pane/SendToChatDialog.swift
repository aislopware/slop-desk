// SendToChatDialog — the E13 WI-5 / ES-E13-5 "Send to Chat" modal (bound to ⌘⌃↩), NATIVE SwiftUI. Everything
// outside the workspace + panes is native chrome, so this is a native `.sheet` body — a grouped `Form` (the
// read-only quoted preview, a native `Picker` of Claude-only sessions, a focused multi-line "Comment" field)
// with a native title + button bar — NOT the old bespoke `OverlayPanel` card. Presented by ``OverlayHostView``.
//
// PURE plumbing over the headless ``SendToChatModel``: it composes the delivered message via
// `SendToChatModel.compose(...)` and hands the chosen target + the composed STRING back through `onSend`
// (the owner resolves that pane's `ComposerModel.send` with `SendToChatModel.payload(for:)` — the single
// ordered-OUT VERBATIM sink — and auto-focuses the pane); Copy Message → `onCopy` (the owner writes the
// pasteboard); Cancel → `onCancel`. Claude-only (BINDING directive 1) — the picker never surfaces codex.
//
// Shared `AislopdeskClientUI` view — the native sheet + `Form` read on both platforms; no dead iOS affordance.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct SendToChatDialog: View {
    /// The captured source — the dialog title (source location), the verbatim quoted preview, and an
    /// optional file-reference line (`nil` for a terminal pane).
    let context: SendToChatContext
    /// The live Claude-only agent sessions the context can be routed to (`composerAgentActive` panes). Empty
    /// ⇒ the picker offers only "New session".
    let sessions: [SendToChatSession]
    /// Send: the chosen target pane (`nil` ⇒ "New session") + the composed VERBATIM message. The owner
    /// resolves the target's `ComposerModel.send` with `SendToChatModel.payload(for:)` and focuses the pane.
    var onSend: (_ target: PaneID?, _ message: String) -> Void
    /// Copy Message: the composed message, copied to the pasteboard WITHOUT sending (the owner writes it —
    /// keeps this view AppKit-free so it compiles on iOS).
    var onCopy: (_ message: String) -> Void
    /// Cancel: dismiss without sending.
    var onCancel: () -> Void
    /// Persist the chosen target as the last-used default (the owner writes the preferences key). `nil` ⇒
    /// not persisted (a preview / test).
    var onSelectionChange: ((PaneID?) -> Void)?

    /// The selected target pane id, or `nil` for "New session". Seeded from the last-used default.
    @State private var selectedSessionID: PaneID?
    /// The user's comment accompanying the context (the spec's "Comment:" field). Starts empty.
    @State private var comment: String = ""
    /// Focus the Comment field on appear (the spec: "this field is focused and active when the dialog opens").
    @FocusState private var commentFocused: Bool

    init(
        context: SendToChatContext,
        sessions: [SendToChatSession],
        initialSelection: PaneID?,
        onSend: @escaping (_ target: PaneID?, _ message: String) -> Void,
        onCopy: @escaping (_ message: String) -> Void,
        onCancel: @escaping () -> Void,
        onSelectionChange: ((PaneID?) -> Void)? = nil,
    ) {
        self.context = context
        self.sessions = sessions
        self.onSend = onSend
        self.onCopy = onCopy
        self.onCancel = onCancel
        self.onSelectionChange = onSelectionChange
        _selectedSessionID = State(initialValue: initialSelection)
    }

    /// The composed VERBATIM message — recomputed as the comment changes (the quoted block + the comment).
    private var composedMessage: String {
        SendToChatModel.compose(context: context, comment: comment)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(context.title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            Form {
                Section("Quoted") {
                    Text(context.quoted)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Picker("Send to", selection: $selectedSessionID) {
                        ForEach(sessions) { session in
                            Text("\(session.name) · \(session.agentLabel)").tag(Optional(session.id))
                        }
                        // "New session" — always offered (the only option when no agent pane is open).
                        Text("New session").tag(PaneID?.none)
                    }
                    .onChange(of: selectedSessionID) { _, new in onSelectionChange?(new) }
                }

                Section("Comment") {
                    TextField("Add a comment…", text: $comment, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($commentFocused)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Button("Copy Message") { onCopy(composedMessage) }
                Spacer(minLength: 0)
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { onSend(selectedSessionID, composedMessage) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        #if os(macOS)
        .frame(width: 520)
        #endif
        .onAppear { DispatchQueue.main.async { commentFocused = true } }
    }
}
#endif
