#if canImport(SwiftUI)
import SwiftUI

/// Host/port entry + connect/disconnect + live status + session id. Binds a
/// ``ConnectionViewModel`` (which owns the ``RworkClient`` + ``ReconnectManager``).
@available(macOS 14.0, iOS 17.0, *)
public struct ConnectionView: View {
    @Bindable private var model: ConnectionViewModel

    public init(model: ConnectionViewModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("host", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                TextField("port", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                connectButton
            }

            HStack(spacing: 8) {
                statusBadge
                if let sid = model.sessionID {
                    Text("session \(sid.uuidString.prefix(8))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let log = model.lastLog {
                    Text(log)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var connectButton: some View {
        switch model.status {
        case .connected, .reconnecting, .connecting:
            Button("Disconnect", role: .destructive) {
                Task { await model.disconnect() }
            }
        case .disconnected, .failed:
            Button("Connect") {
                Task { await model.connect() }
            }
            .disabled(!model.canConnect)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(badgeColor).frame(width: 8, height: 8)
            Text(model.status.label)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var badgeColor: Color {
        switch model.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}
#endif
