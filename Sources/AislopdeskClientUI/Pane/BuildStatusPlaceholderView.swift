// BuildStatusPlaceholderView — the HEADLESS terminal-renderer fallback (REBUILD-V2, L2).
//
// The cross-platform `AislopdeskClientUI` library must NOT import libghostty/Metal. The production
// renderer (`GhosttyTerminalView`) is injected by the Xcode app target via `TerminalRendererFactory`.
// When no factory is registered (a headless `swift build`, previews, or this library running without the
// app target) the terminal leaf renders THIS panel instead — build-status telemetry over the pane bg, not
// an emulated terminal (libghostty IS the renderer per DECISIONS / doc 17).
//
// It reads only `TerminalViewModel` connection state + bytes-received (no surface attach), so it is safe
// in tests and previews. SYSTEM colours/fonts only — NO design-system, NO libghostty/Metal import.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// The headless build-status placeholder for a terminal pane. Conforms to the seam's
/// ``TerminalRenderingView`` so the app target could register it as a debug factory if desired; the
/// library mounts it directly when `TerminalRendererFactory.shared == nil`.
struct BuildStatusPlaceholderView: TerminalRenderingView {
    private let model: TerminalViewModel

    init(model: TerminalViewModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemSymbol: .appleTerminal)
                .font(.system(size: Otty.Typeface.display, weight: .regular))
                .foregroundStyle(.secondary)
            Text("terminal")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Run ThirdParty/ghostty/build-libghostty.sh — the headless build renders this panel.")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            statusLine
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    @ViewBuilder private var statusLine: some View {
        let status = model.connectionStatus
        HStack(spacing: 6) {
            Circle()
                .fill(status.isLive ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text("\(status.label) · \(model.bytesReceived) bytes")
                .font(.system(size: Otty.Typeface.footnote).monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
#endif
