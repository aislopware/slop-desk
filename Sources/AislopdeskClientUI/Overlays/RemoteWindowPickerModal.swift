// RemoteWindowPickerModal — the MODAL Remote-Window picker overlay (E2 / WI-5, ES-E2-6 second clause). Opened
// by the palette's "New Remote Window Tab" action (`openRemotePicker()`), it lists the host's shareable
// windows and, on pick, opens a NEW `.remoteGUI` tab pre-bound to that window — the app-global counterpart of
// the in-pane ``RemoteWindowPickerView`` (which binds a single pane's model and streams into THAT pane).
//
// Bound to ``OverlayCoordinator/remotePickerModel`` (a fresh ``RemoteWindowModel`` built per open against the
// live app target), it reuses the in-pane picker's row/filter/manual-fallback idiom but routes a pick through
// ``OverlayCoordinator/openRemoteWindow(_:)`` (open a tab + close the modal) instead of the pane's
// `pick()→open()`. Discovery runs once on appear via `model.refresh()`.
//
// SEAM discipline: this view NEVER imports `AislopdeskVideoClient` — discovery crosses the
// `RemoteWindowDiscovery` seam already wired into ``RemoteWindowModel`` (a closure the app injects). Shares the
// family panel shell via ``OverlayPanel``. `Otty.*` tokens ONLY (raw font/radius literals fail
// `scripts/check-ds-leaks.sh`). Shared `AislopdeskClientUI` view — compiles for iOS (only the AppKit Esc
// handler is `#if os(macOS)`-gated).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct RemoteWindowPickerModal: View {
    /// The single overlay reducer — owns the live ``RemoteWindowModel`` (`remotePickerModel`) the modal binds,
    /// and the `openRemoteWindow(_:)` / `closeRemotePicker()` actions a pick / Cancel fire.
    let coordinator: OverlayCoordinator

    /// The filter query narrowing the discovered window list (token-AND over title + app name).
    @State private var filter: String = ""
    /// The manual window-id entry for the no-discovery fallback.
    @State private var manualID: String = ""
    /// Whether the demoted manual-id fallback is revealed. Collapsed by default — the list leads.
    @State private var showManualEntry = false
    /// Focus the panel on appear so Esc reaches `.onExitCommand` even before the filter field exists
    /// (loading / empty states have no text field to take first responder).
    @FocusState private var panelFocused: Bool

    private let panelWidth: CGFloat = 520
    private let listMaxHeight: CGFloat = 360

    var body: some View {
        OverlayPanel(width: panelWidth) {
            VStack(alignment: .leading, spacing: Otty.Metric.space3) {
                header
                if let model = coordinator.remotePickerModel {
                    windowSection(model)
                    manualEntrySection
                }
            }
            .padding(Otty.Metric.space4)
        }
        // Discover once on appear (the modal's model is freshly built per open, so it always queries the
        // current host). A nil model (shouldn't happen while presented) is a safe no-op.
        .task { await coordinator.remotePickerModel?.refresh() }
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onAppear { DispatchQueue.main.async { panelFocused = true } }
        #if os(macOS)
            .onExitCommand { coordinator.closeRemotePicker() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                coordinator.closeRemotePicker()
                return .handled
            }
        #endif
    }

    // MARK: - Header (title + Refresh)

    private var header: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemSymbol: .display)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            Text("New Remote Window")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: Otty.Metric.space2)
            if let model = coordinator.remotePickerModel {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemSymbol: .arrowClockwise)
                        .font(.system(size: Otty.Typeface.footnote))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Otty.Text.secondary)
                .disabled(model.isLoading)
            }
        }
    }

    // MARK: - Window list — the PRIMARY surface (loading / list / empty)

    @ViewBuilder
    private func windowSection(_ model: RemoteWindowModel) -> some View {
        if model.isLoading, model.availableWindows.isEmpty {
            loadingRow
        } else if model.availableWindows.isEmpty {
            emptyState(model)
        } else {
            filterField
            windowList(model)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: Otty.Metric.space2) {
            ProgressView().controlSize(.small)
            Text("Looking for shareable windows…")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
        }
    }

    private func emptyState(_ model: RemoteWindowModel) -> some View {
        Text(model.loadError ?? "No shareable windows on the host yet.")
            .font(.system(size: Otty.Typeface.footnote))
            .foregroundStyle(Otty.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var filterField: some View {
        TextField("Filter windows", text: $filter)
            .textFieldStyle(.plain)
            .font(.system(size: Otty.Typeface.footnote))
            .foregroundStyle(Otty.Text.primary)
            .tint(Otty.State.accent)
            .padding(Otty.Metric.space2)
            .background(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .fill(Otty.Surface.element),
            )
    }

    @ViewBuilder
    private func windowList(_ model: RemoteWindowModel) -> some View {
        let windows = RemoteWindowModel.filtered(model.availableWindows, query: filter)
        if windows.isEmpty {
            Text(RemoteWindowModel.windowFilterEmptyMessage(
                filter: filter, totalCount: model.availableWindows.count,
            ))
            .font(.system(size: Otty.Typeface.footnote))
            .foregroundStyle(Otty.Text.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                    ForEach(windows) { window in
                        windowRow(window)
                    }
                }
            }
            .frame(maxHeight: listMaxHeight)
        }
    }

    private func windowRow(_ window: RemoteWindowSummary) -> some View {
        Button {
            // A pick opens a NEW `.remoteGUI` tab pre-bound to this window, then closes the modal — the
            // app-global path (NOT the in-pane `pick()→open()`).
            coordinator.openRemoteWindow(window)
        } label: {
            HStack(spacing: Otty.Metric.space2) {
                Image(systemSymbol: .macwindow)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.secondary)
                Text(window.displayLabel)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Otty.Metric.space1)
            .padding(.horizontal, Otty.Metric.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Manual fallback (DEMOTED — collapsed disclosure under the list)

    @ViewBuilder private var manualEntrySection: some View {
        if showManualEntry {
            manualField
        } else {
            Button {
                showManualEntry = true
            } label: {
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemSymbol: .keyboard)
                        .font(.system(size: Otty.Typeface.small))
                    Text("Enter window ID manually")
                        .font(.system(size: Otty.Typeface.footnote))
                }
                .foregroundStyle(Otty.Text.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var manualField: some View {
        HStack(spacing: Otty.Metric.space2) {
            TextField("Window id", text: $manualID)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.footnote).monospaced())
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent)
                .padding(Otty.Metric.space2)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .fill(Otty.Surface.element),
                )
                .onSubmit { openManual() }
            Button("Open") { openManual() }
                .buttonStyle(.plain)
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                .foregroundStyle(parsedManualID != nil ? Otty.State.accent : Otty.Text.tertiary)
                .disabled(parsedManualID == nil)
        }
    }

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
