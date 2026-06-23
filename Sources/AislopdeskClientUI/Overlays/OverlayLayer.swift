// OverlayLayer — the single floating-overlay layer mounted in a ZStack ABOVE the whole window
// (warp-overlays-actions.md §9). It composes, in z-order: the command palette, the busy-close confirm
// modal (driven off the store's `pendingCloseSpec`), the Settings overlay, and the toast stack. Each is
// conditionally present; the palette/modal/settings are click-blocking, the toasts are not.
//
// Mounted by `WorkspaceRootView` so palette/modal/toast float above the rail + panes. The coordinator owns
// palette/settings/toast state; the modal reads the store directly.

import AislopdeskWorkspaceCore
import SwiftUI

struct OverlayLayer: View {
    @Bindable var coordinator: OverlayCoordinator
    let store: WorkspaceStore
    /// The Settings model (UserDefaults-backed) — owned by the root so it persists across opens.
    @Bindable var settings: SettingsModel
    /// The app-global connection — bound by the Connect-to-Host overlay (host/port editor).
    @Bindable var connection: AppConnection
    var staticMirror: Bool = false

    var body: some View {
        ZStack {
            // Toasts sit at the bottom-most z so the palette/modal cover them when open.
            ToastStackView(coordinator: coordinator)

            if coordinator.paletteVisible {
                CommandPaletteView(coordinator: coordinator, staticMirror: staticMirror)
            }

            // Busy-shell close confirmation — driven by the store's pendingCloseSpec.
            if let spec = store.pendingCloseSpec {
                ConfirmModal(
                    title: "Close pane with a running process?",
                    message: closeMessage(for: spec),
                    confirmLabel: "Close",
                    cancelLabel: "Cancel",
                    destructive: true,
                    onConfirm: { store.confirmPendingClose() },
                    onCancel: { store.cancelPendingClose() },
                )
            }

            if coordinator.settingsVisible {
                SettingsOverlay(model: settings, staticMirror: staticMirror, onClose: { coordinator.closeSettings() })
            }

            // The Connect-to-Host editor (top-bar pill + the "Connect to Host…" palette action) — the only
            // surface that lets a user point the client at a non-default host.
            if coordinator.connectVisible {
                ConnectHostOverlay(
                    connection: connection,
                    staticMirror: staticMirror,
                    onClose: { coordinator.closeConnect() },
                )
            }

            // Keyboard cheat sheet (⌘/ + the palette "Keyboard Shortcuts" row) — registry-generated.
            if coordinator.cheatSheetVisible {
                CheatSheetOverlay(staticMirror: staticMirror, onClose: { coordinator.closeCheatSheet() })
            }

            // L6 / W1: the Remote-Window picker (opened by the /remote-control pill + the palette action).
            if coordinator.remotePickerVisible, let model = coordinator.remotePickerModel {
                RemoteWindowPicker(
                    model: model,
                    onOpen: { coordinator.openRemoteWindow($0) },
                    onCancel: { coordinator.closeRemotePicker() },
                    staticMirror: staticMirror,
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func closeMessage(for spec: PaneSpec) -> String {
        let name = spec.lastKnownTitle ?? spec.title
        let label = name.isEmpty ? "This pane" : "“\(name)”"
        return "\(label) still has a command running. Closing it will terminate the process."
    }
}
