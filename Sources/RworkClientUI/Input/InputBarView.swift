#if canImport(SwiftUI)
import SwiftUI
import RworkClaudeCode
import RworkClient

/// The external input affordance (doc 14 A + B1): a compose field that sends via
/// `RworkClient.sendInput`, switching its label/behaviour with the ``InputBarModel``'s
/// affordance (shell-command 'A' vs TUI-compose 'B1'). The logic lives in
/// `RworkClaudeCode.InputBoxModel`; this is the view.
@available(macOS 14.0, iOS 17.0, *)
public struct InputBarView: View {
    @Bindable private var model: InputBarModel
    private let client: RworkClient?

    public init(model: InputBarModel, client: RworkClient?) {
        _model = Bindable(model)
        self.client = client
    }

    public var body: some View {
        HStack(spacing: 8) {
            modeBadge
            TextField(placeholder, text: $model.compose, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(client == nil || model.compose.isEmpty)
        }
        .padding(8)
    }

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
