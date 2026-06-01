#if canImport(SwiftUI)
import SwiftUI

/// The terminal screen: hosts the ``TerminalRenderingView`` seam (production
/// `GhosttyTerminalView` via ``TerminalRendererFactory``, or the BUILD-STATUS placeholder)
/// plus a thin status/title overlay. Binds a ``TerminalViewModel``.
///
/// The view itself is renderer-agnostic — it asks the factory for the rendering view and
/// lays a title bar over it. The byte pipeline is driven by `observe(client:)`, started by
/// the embedding scene (`RworkClientApp`) so this view can be reused inside the split layout.
@available(macOS 14.0, iOS 17.0, *)
public struct TerminalScreenView: View {
    @State private var model: TerminalViewModel

    public init(model: TerminalViewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // The renderer seam — production GhosttyTerminalView, or the placeholder.
            TerminalRendererFactory.make(model: model)
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

@available(macOS 14.0, iOS 17.0, *)
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
