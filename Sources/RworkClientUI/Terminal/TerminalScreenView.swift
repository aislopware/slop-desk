#if canImport(SwiftUI)
import SwiftUI

/// The terminal screen: hosts the ``TerminalRenderingView`` seam (production
/// `GhosttyTerminalView` via ``TerminalRendererFactory``, or the BUILD-STATUS placeholder)
/// plus a thin status/title overlay. Binds a ``TerminalViewModel``.
///
/// The view itself is renderer-agnostic — it asks the factory for the rendering view and
/// lays a title bar over it. The byte pipeline is driven by `observe(client:)`, started by
/// the embedding scene (`RworkClientApp`) so this view can be reused inside the split layout.
public struct TerminalScreenView: View {
    @State private var model: TerminalViewModel
    /// The pane's workspace focus, threaded to the renderer so only the focused pane takes the macOS
    /// keyboard first responder (a plain `let`, NOT `@State`, so a focus change re-renders and updates
    /// the renderer; the model stays stable in `@State`). Defaults to `true` for the single-pane /
    /// preview callers that do not thread focus.
    private let isFocused: Bool

    public init(model: TerminalViewModel, isFocused: Bool = true) {
        _model = State(initialValue: model)
        self.isFocused = isFocused
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // The renderer seam — production GhosttyTerminalView, or the placeholder.
            TerminalRendererFactory.make(model: model, isFocused: isFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Title / status strip.
            HStack(spacing: 8) {
                StatusDot(status: model.connectionStatus)
                Text(model.title ?? "Terminal")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(model.connectionStatus.label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }
}

struct StatusDot: View {
    let status: TerminalViewModel.ConnectionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        case .exited: return .gray
        case .idle: return .secondary
        }
    }
}
#endif
