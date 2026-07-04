// RemoteWindowPickerView — the in-pane Remote-Window picker FORM (WS-A / A3). Bound to the pane's live
// ``RemoteWindowModel`` (extracted, headless logic in `AislopdeskWorkspaceCore`), it lists the host's
// shareable windows (`refresh()` over the `RemoteWindowDiscovery` seam), filters them token-AND, and lets
// the user PICK one to `open()` the live video stream.
//
// LIST-FIRST: choosing a window means picking from the discovered list — that is the primary (and, while
// connected, the only) surface. The manual "enter a CGWindowID" field is a DEMOTED, collapsed fallback for
// the degraded case (no discovery seam / host returned nothing / not yet connected); it never fronts the
// list. So a connected user always picks from a list, and the id box is one deliberate tap away when
// discovery can't help.
//
// Shown by ``GuiLeafView`` ONLY when `model.active == nil` AND a cap slot is free (`RemoteGUIDisplay`
// resolves to `.entryForm`). On `pick → open` the model fires `onEndpointCommitted`, which the store's
// `wireMaterializedLeaf` persists into the pane's `spec.video` (PANE REBIND).
//
// SEAM discipline: this view NEVER imports `AislopdeskVideoClient` — discovery crosses the
// `RemoteWindowDiscovery` seam (a closure injected by the app target). Design-system tokens ONLY (`Slate.*`);
// raw font/colour/radius literals fail `scripts/check-ds-leaks.sh`.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct RemoteWindowPickerView: View {
    /// The pane's live remote-window model (the picker logic + the open()/pick() actions live here).
    let model: RemoteWindowModel
    /// Activates this pane in the workspace when the user interacts with the form (so a click on a
    /// background pane's picker focuses it first).
    var onActivate: () -> Void = {}

    /// The filter query narrowing the discovered window list (token-AND over title + app name).
    @State private var filter: String = ""
    /// The manual window-id entry for the no-discovery fallback.
    @State private var manualID: String = ""
    /// Whether the demoted manual-id fallback is revealed. Collapsed by default — the list leads; the user
    /// opts into typing a raw CGWindowID only when discovery can't surface their window.
    @State private var showManualEntry = false

    /// The discovered windows narrowed by the current filter (pure, shared with the headless tests).
    private var filteredWindows: [RemoteWindowSummary] {
        RemoteWindowModel.filtered(model.availableWindows, query: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
            header
            windowSection
            manualEntrySection
        }
        .padding(Slate.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NativePaneColor.terminalBackground)
        // Discover on appear; a background pane's picker still loads so it is ready the moment it focuses.
        .task { await model.refresh() }
        // Any interaction focuses the pane first (a click on a non-active pane's picker activates it).
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
    }

    // MARK: Header (title + Refresh)

    private var header: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .display)
                .font(.system(size: Slate.Typeface.body, weight: .regular))
                .foregroundStyle(Slate.Text.secondary)
            Text("Remote window")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Spacer(minLength: Slate.Metric.space2)
            Button {
                onActivate()
                Task { await model.refresh() }
            } label: {
                Image(systemSymbol: .arrowClockwise)
                    .font(.system(size: Slate.Typeface.footnote, weight: .regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Slate.Text.secondary)
            .disabled(model.isLoading)
        }
    }

    // MARK: Window list — the PRIMARY surface (loading / list / empty)

    @ViewBuilder private var windowSection: some View {
        if model.isLoading, model.availableWindows.isEmpty {
            loadingRow
        } else if model.availableWindows.isEmpty {
            emptyState
        } else {
            filterField
            windowList
        }
    }

    private var loadingRow: some View {
        HStack(spacing: Slate.Metric.space2) {
            ProgressView().controlSize(.small)
            Text("Looking for shareable windows…")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
        }
    }

    /// Discovery finished with no windows (host has none / no screen-recording permission / not connected).
    /// Names the likely cause and points at the manual fallback below — the list stays the headline, the id
    /// box never fronts it.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            Text(model.loadError ?? "No shareable windows on the host yet.")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filterField: some View {
        TextField(
            "Filter windows",
            text: $filter,
        )
        .textFieldStyle(.plain)
        .font(.system(size: Slate.Typeface.footnote))
        .foregroundStyle(Slate.Text.primary)
        .padding(Slate.Metric.space2)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .fill(Slate.Surface.element),
        )
    }

    @ViewBuilder private var windowList: some View {
        let windows = filteredWindows
        if windows.isEmpty {
            Text(RemoteWindowModel.windowFilterEmptyMessage(filter: filter, totalCount: model.availableWindows.count))
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    ForEach(windows) { window in
                        windowRow(window)
                    }
                }
            }
        }
    }

    private func windowRow(_ window: RemoteWindowSummary) -> some View {
        Button {
            onActivate()
            // pickAndOpen (not bare pick+open): opens optimistically, then revalidates against a fresh host
            // query so a window that closed between the list fetch and this tap falls back to the picker with
            // an error instead of streaming a permanent black surface (host rejects a dead id silently).
            model.pickAndOpen(window)
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Image(systemSymbol: .macwindow)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                Text(window.displayLabel)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Slate.Metric.space1)
            .padding(.horizontal, Slate.Metric.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Manual fallback (DEMOTED — collapsed disclosure under the list)

    @ViewBuilder private var manualEntrySection: some View {
        if showManualEntry {
            manualField
        } else {
            Button {
                onActivate()
                showManualEntry = true
            } label: {
                HStack(spacing: Slate.Metric.space1) {
                    Image(systemSymbol: .keyboard)
                        .font(.system(size: Slate.Typeface.small))
                    Text("Enter window ID manually")
                        .font(.system(size: Slate.Typeface.footnote))
                }
                .foregroundStyle(Slate.Text.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var manualField: some View {
        HStack(spacing: Slate.Metric.space2) {
            TextField("Window id", text: $manualID)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.footnote).monospaced())
                .foregroundStyle(Slate.Text.primary)
                .padding(Slate.Metric.space2)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.Surface.element),
                )
                .onSubmit { openManual() }
            Button("Open") { openManual() }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(canOpenManual ? Slate.State.accent : Slate.Text.tertiary)
                .disabled(!canOpenManual)
        }
    }

    private var canOpenManual: Bool {
        !manualID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func openManual() {
        guard canOpenManual else { return }
        onActivate()
        model.windowID = manualID
        guard model.canOpen else { return }
        model.open()
    }
}
#endif
