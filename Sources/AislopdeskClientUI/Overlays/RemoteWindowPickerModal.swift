// RemoteWindowPickerModal — the Remote-Window picker, NATIVE SwiftUI (E2 / WI-5, ES-E2-6 second clause).
// Opened by the palette's "New Remote Window Tab" action (`openRemotePicker()`), it lists the host's
// shareable windows and, on pick, opens a NEW `.remoteGUI` tab pre-bound to that window — the app-global
// counterpart of the in-pane ``RemoteWindowPickerView``.
//
// Everything outside the workspace + panes is native chrome, so this is a native `.sheet` body — a grouped
// `Form` (a filter field + a `Button` row per discovered window + a manual-id fallback section) with a native
// title + Cancel bar — NOT the old bespoke `OverlayPanel` card. Presented as a real sheet by ``OverlayHostView``.
//
// Bound to ``OverlayCoordinator/remotePickerModel`` (a fresh ``RemoteWindowModel`` built per open against the
// live app target), it routes a pick through ``OverlayCoordinator/openRemoteWindow(_:)`` (open a tab + close
// the modal). Discovery runs once on appear via `model.refresh()`.
//
// SEAM discipline: this view NEVER imports `AislopdeskVideoClient` — discovery crosses the
// `RemoteWindowDiscovery` seam already wired into ``RemoteWindowModel``. Shared `AislopdeskClientUI` view —
// compiles for iOS (the native sheet + `Form` read on both platforms).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct RemoteWindowPickerModal: View {
    /// The single overlay reducer — owns the live ``RemoteWindowModel`` (`remotePickerModel`) the modal binds,
    /// and the `openRemoteWindow(_:)` / `closeRemotePicker()` actions a pick / Cancel fire.
    let coordinator: OverlayCoordinator

    /// The filter query narrowing the discovered window list (token-AND over title + app name).
    @State private var filter: String = ""
    /// The manual window-id entry for the no-discovery fallback.
    @State private var manualID: String = ""

    var body: some View {
        VStack(spacing: 0) {
            SlateSheetHeader("New Remote Window") {
                if let model = coordinator.remotePickerModel {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isLoading)
                    .help("Refresh the window list")
                }
            }

            if let model = coordinator.remotePickerModel {
                windowForm(model)
            }

            SlateSheetFooter {
                Button("Cancel") { coordinator.closeRemotePicker() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        #if os(macOS)
        .frame(width: 520)
        #endif
        // Discover once on appear (the modal's model is freshly built per open, so it always queries the
        // current host). A nil model (shouldn't happen while presented) is a safe no-op.
        .task { await coordinator.remotePickerModel?.refresh() }
    }

    // MARK: - Form (windows + manual fallback)

    private func windowForm(_ model: RemoteWindowModel) -> some View {
        Form {
            Section("Shareable windows") {
                if model.isLoading, model.availableWindows.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for shareable windows…").foregroundStyle(.secondary)
                    }
                } else if model.availableWindows.isEmpty {
                    Text(model.loadError ?? "No shareable windows on the host yet.")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Filter windows", text: $filter)
                    windowRows(model)
                }
            }

            Section("Or enter a window ID") {
                HStack(spacing: 8) {
                    TextField("Window id", text: $manualID)
                        .font(.body.monospaced())
                        .onSubmit { openManual() }
                    Button("Open") { openManual() }
                        .disabled(parsedManualID == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func windowRows(_ model: RemoteWindowModel) -> some View {
        let windows = RemoteWindowModel.filtered(model.availableWindows, query: filter)
        if windows.isEmpty {
            Text(RemoteWindowModel.windowFilterEmptyMessage(
                filter: filter, totalCount: model.availableWindows.count,
            ))
            .foregroundStyle(.secondary)
        } else {
            ForEach(windows) { window in
                Button {
                    // A pick opens a NEW `.remoteGUI` tab pre-bound to this window, then closes the modal.
                    coordinator.openRemoteWindow(window)
                } label: {
                    Label(window.displayLabel, systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Manual fallback

    /// The typed manual window id parsed to a `CGWindowID`, or nil when blank/invalid (the Open button's
    /// enabled state — validate-then-open, never a force-unwrap).
    private var parsedManualID: UInt32? {
        UInt32(manualID.trimmingCharacters(in: .whitespaces))
    }

    /// Opens a remote window tab for the manually-entered id (the no-discovery fallback). Builds a minimal
    /// summary (no app/title/size — discovery couldn't surface them) and routes it through the SAME
    /// `openRemoteWindow` path a list pick uses.
    private func openManual() {
        guard let wid = parsedManualID else { return }
        coordinator.openRemoteWindow(
            RemoteWindowSummary(windowID: wid, appName: "", title: "", width: 0, height: 0),
        )
    }
}
#endif
