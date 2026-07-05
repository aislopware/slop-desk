// BuildStatusPlaceholderView — the HEADLESS terminal-renderer fallback (REBUILD-V2, L2).
//
// The cross-platform `SlopDeskClientUI` library must NOT import libghostty/Metal. The production
// renderer (`GhosttyTerminalView`) is injected by the Xcode app target via `TerminalRendererFactory`.
// When no factory is registered (a headless `swift build`, previews, or this library running without the
// app target) the terminal leaf renders THIS panel instead — build-status telemetry over the pane bg, not
// an emulated terminal (libghostty IS the renderer per DECISIONS / doc 17).
//
// It reads only `TerminalViewModel` connection state + bytes-received (no surface attach), so it is safe
// in tests and previews. Text/dot colours route through the `Slate.*` token layer (so the placeholder reads
// as the active theme over the themed pane backdrop) — NO libghostty/Metal import.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
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
                .font(.system(size: Slate.Typeface.display, weight: .regular))
                .foregroundStyle(Slate.Text.secondary)
            Text("terminal")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Text("Run ThirdParty/ghostty/build-libghostty.sh — the headless build renders this panel.")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
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
                .fill(status.isLive ? Slate.Status.ok : Slate.Text.secondary)
                .frame(width: 7, height: 7)
            Text("\(status.label) · \(model.bytesReceived) bytes")
                .font(.system(size: Slate.Typeface.footnote).monospaced())
                .foregroundStyle(Slate.Text.secondary)
        }
    }
}
#endif
