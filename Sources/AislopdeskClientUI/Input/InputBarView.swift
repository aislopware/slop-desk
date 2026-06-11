#if canImport(SwiftUI)
import SwiftUI
import AislopdeskClaudeCode
import AislopdeskClient

/// The external input affordance (doc 14 A + B1): a compose field that sends via
/// `AislopdeskClient.sendInput`, switching its label/behaviour with the ``InputBarModel``'s
/// affordance (shell-command 'A' vs TUI-compose 'B1'). The logic lives in
/// `AislopdeskClaudeCode.InputBoxModel`; this is the view.
public struct InputBarView: View {
    @Bindable private var model: InputBarModel
    private let client: AislopdeskClient?
    /// The pane this input surface backs — forwarded to the iOS ``TerminalInputHost`` so the
    /// ``PaneFocusCoordinator`` can register/resolve first-responder for the right pane (docs/22 §7).
    /// `nil` falls back to a fresh id (no coordination — the compact single-host path is unaffected).
    private let paneID: PaneID?
    /// The single-focus arbiter for the multi-visible iPad-regular path (docs/22 §7). `nil` ⇒ no
    /// coordination (compact / macOS), preserving the pre-WF6 direct-claim behaviour.
    private let focusCoordinator: PaneFocusCoordinator?

    public init(
        model: InputBarModel,
        client: AislopdeskClient?,
        paneID: PaneID? = nil,
        focusCoordinator: PaneFocusCoordinator? = nil
    ) {
        _model = Bindable(model)
        self.client = client
        self.paneID = paneID
        self.focusCoordinator = focusCoordinator
    }

    public var body: some View {
        HStack(spacing: 8) {
            modeBadge
            composeField
            #if os(macOS)
            // macOS sends the composed line on the paperplane / Enter. On iOS the
            // `TerminalInputHost` streams keystrokes directly (text + keys → `sendInput`), so
            // there is no separate compose buffer to flush with a button.
            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(client == nil || model.compose.isEmpty)
            #endif
        }
        .padding(8)
    }

    @ViewBuilder
    private var composeField: some View {
        #if os(iOS)
        // iOS native-feel input surface: the `TerminalInputHost` `UIResponder` assembles the four
        // table-stakes components (KeyRepeater / KeyboardAccessoryBar / IMEProxyTextView /
        // FloatingCursorController) and routes every keystroke straight to `AislopdeskClient.sendInput`.
        TerminalInputHost(
            model: model,
            client: client,
            paneID: paneID ?? PaneID(),
            // Never register a coordinator under an ephemeral (no-paneID) key: a coordinator only
            // makes sense with a STABLE paneID. A mis-wired caller (coordinator but nil paneID)
            // degrades to the compact direct-claim path instead of an unstable registration.
            coordinator: paneID == nil ? nil : focusCoordinator
        )
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
        #else
        TextField(placeholder, text: $model.compose, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .onSubmit { send() }
        #endif
    }

    #if os(macOS)
    private func send() {
        guard let client else { return }
        Task { await model.submit(over: client) }
    }

    private var placeholder: String {
        switch model.affordance {
        case .shellCommand:
            return model.commandRunning ? "command running…" : "shell command"
        case .tuiCompose:
            return "compose (TUI)"
        }
    }
    #endif

    private var modeBadge: some View {
        Text(model.affordance == .shellCommand ? "A" : "B1")
            .font(.system(.caption2, design: .monospaced).bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }

    private var badgeColor: Color {
        switch model.affordance {
        case .shellCommand: return .blue
        case .tuiCompose: return .purple
        }
    }
}
#endif
