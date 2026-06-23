// ConnectHostOverlay — the host/port editor (ORCH D1 replacement for the deleted ConnectionGateView).
// Surfaces the already-complete app-global `AppConnection` form (host / port / mediaPort / cursorPort)
// the rewrite left unbound by any view, so a user can point the client at a NON-default host. Opened by
// the top-bar status pill and the "Connect to Host…" palette action.
//
// A centered modal card over the 70% scrim (mirrors SettingsOverlay): four labeled text fields bound to
// the @Observable connection, a "Recent Hosts" menu that fills the form from the MRU, and a Connect
// button gated on `connection.canConnect` (the why-disabled `validationHint` shows as subtext). On a
// successful connect (`status == .connected`) the overlay closes. Esc / scrim-tap / Done dismiss without
// connecting. Pure view + wiring — all validation / MRU / lifecycle lives in `AppConnection`.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct ConnectHostOverlay: View {
    @Environment(\.theme) private var theme

    @Bindable var connection: AppConnection
    var staticMirror: Bool = false
    let onClose: () -> Void

    private static let width: CGFloat = 460

    var body: some View {
        ZStack {
            Color(WarpShadow.modalBackdrop)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS) || os(iOS)
            .modifier(ConnectEscHandler(enabled: !staticMirror, onClose: onClose))
        #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: WarpSpace.l) {
            HStack {
                Text("Connect to Host")
                    .font(WarpType.ui(WarpType.headerSize, weight: .semibold))
                    .foregroundStyle(theme.textMain)
                Spacer()
                if !connection.recentTargets.isEmpty {
                    recentMenu
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: WarpType.uiSize, weight: .semibold))
                        .foregroundStyle(theme.textSub)
                        .frame(width: WarpSize.iconButton, height: WarpSize.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            field(label: "Host", text: $connection.host, placeholder: "127.0.0.1")
            field(label: "Port", text: $connection.port, placeholder: "7420")
            field(label: "Media Port", text: $connection.mediaPort, placeholder: "9000")
            field(label: "Cursor Port", text: $connection.cursorPort, placeholder: "9001")

            // Why-disabled subtext (nil ⟺ canConnect), so the dimmed Connect button explains itself.
            if let hint = connection.validationHint {
                Text(hint)
                    .font(WarpType.ui(WarpType.overlineSize))
                    .foregroundStyle(theme.uiWarning)
            }

            HStack {
                Spacer()
                ModalButton(label: "Cancel", kind: .secondary, action: onClose)
                connectButton
            }
        }
        .padding(WarpSpace.dialogHorizontal)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous).fill(theme.surface2),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
        )
        .contentShape(RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous))
        .onTapGesture {}
    }

    // The Connect button is disabled until the form parses (`canConnect`); on submit it dials the
    // committed target and — once the lifecycle reaches `.connected` — closes the overlay.
    private var connectButton: some View {
        ModalButton(label: "Connect", kind: .primary) {
            guard connection.canConnect else { return }
            Task {
                await connection.connect()
                if case .connected = connection.status { onClose() }
            }
        }
        .opacity(connection.canConnect ? 1 : 0.5)
        .disabled(!connection.canConnect)
    }

    /// The "Recent Hosts" MRU menu — a pick fills the form (the user still presses Connect).
    private var recentMenu: some View {
        Menu {
            ForEach(Array(connection.recentTargets.enumerated()), id: \.offset) { _, target in
                Button("\(target.host):\(target.port)") { connection.fillForm(from: target) }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: WarpType.uiSize, weight: .regular))
                .foregroundStyle(theme.textSub)
                .frame(width: WarpSize.iconButton, height: WarpSize.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent hosts")
    }

    private func field(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: WarpSpace.xxs) {
            Text(label)
                .font(WarpType.ui(WarpType.overlineSize, weight: .semibold))
                .foregroundStyle(theme.textSub)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(WarpType.ui(WarpType.uiSize))
                .foregroundStyle(theme.textMain)
                .padding(.horizontal, WarpSpace.m)
                .frame(height: WarpSize.controlHeightSmall)
                .background(
                    RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.surface1),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                        .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
                )
        }
    }
}

#if os(macOS) || os(iOS)
private struct ConnectEscHandler: ViewModifier {
    let enabled: Bool
    let onClose: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onKeyPress(.escape) { onClose()
                return .handled
            }
        } else {
            content
        }
    }
}
#endif
