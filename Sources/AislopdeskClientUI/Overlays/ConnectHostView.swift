// ConnectHostView — the Connect-to-Host editor overlay (E2 / WI-5, ES-E2-6). A THIN form over the app-global
// ``AppConnection`` (which already owns the editable host/port fields, the parse/validation, and the
// `connect()` lifecycle) — opened by the top-bar connection pill (`onTap → openConnect`) and the palette's
// "Connect to Host…" action, the only surfaces that point the client at a non-default host.
//
// The view binds the existing form fields; it builds NO new connection model and never force-unwraps a parsed
// target — the "Connect" button is gated on ``AppConnection/canConnect`` (which is `parsedTarget() != nil`),
// and `connect()` itself re-guards the parse internally, so an invalid form can never crash the path
// (validate-then-connect, per the untrusted-input discipline). The host/port are the headline fields; the two
// video ports sit behind an "Advanced" disclosure (most users keep the defaults).
//
// SEAM discipline: the view owns only its local focus + disclosure UI state; every connection mutation goes
// through the bound ``AppConnection``, and the overlay open/close goes through the ``OverlayCoordinator``.
// Shares the family panel shell via ``OverlayPanel``. `Otty.*` tokens ONLY (raw font/radius literals fail
// `scripts/check-ds-leaks.sh`). Shared `AislopdeskClientUI` view — compiles for iOS (only the AppKit Esc
// handler is `#if os(macOS)`-gated).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct ConnectHostView: View {
    /// The app-global connection — `@Bindable` so the text fields two-way edit its form, and `body`
    /// re-renders on `status` / `validationHint` / `canConnect` changes.
    @Bindable var connection: AppConnection
    /// The single overlay reducer — the view's only overlay mutation is `closeConnect()` (Cancel / Esc / a
    /// successful connect).
    let coordinator: OverlayCoordinator

    /// Whether the advanced (video-port) disclosure is expanded. Collapsed by default — the host/port lead.
    @State private var showAdvanced = false
    /// Pre-focuses the host field on appear (the first thing a user edits).
    @FocusState private var hostFocused: Bool

    private let panelWidth: CGFloat = 460

    var body: some View {
        OverlayPanel(width: panelWidth) {
            VStack(alignment: .leading, spacing: Otty.Metric.space3) {
                titleBar
                Rectangle()
                    .fill(Otty.Line.divider)
                    .frame(height: Otty.Metric.hairline)
                field(
                    label: "Host", text: $connection.host, placeholder: "host.local or 10.0.0.7",
                    focused: $hostFocused,
                )
                field(label: "Port", text: $connection.port, placeholder: "9000", mono: true)
                advancedSection
                if let hint = connection.validationHint {
                    hintRow(hint)
                }
                buttonRow
            }
            .padding(Otty.Metric.space4)
        }
        .onAppear {
            // Seed the fields from the committed target (re-editing the live host), then defer focus a
            // runloop hop (a `@FocusState` set the same tick the view appears is dropped before its responder
            // exists — the same idiom the palette uses).
            connection.fillForm(from: connection.target)
            DispatchQueue.main.async { hostFocused = true }
        }
        #if os(macOS)
        .onExitCommand { coordinator.closeConnect() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            coordinator.closeConnect()
            return .handled
        }
        #endif
    }

    // MARK: - Title

    private var titleBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemSymbol: .network)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            Text("Connect to Host")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: Otty.Metric.space2)
        }
    }

    // MARK: - Fields

    /// One labeled inset text field (the inset plate + label stacked above it). `focused` is threaded onto the
    /// inner `TextField` (NOT the wrapper) when provided, so the host field can pre-focus correctly.
    private func field(
        label: String, text: Binding<String>, placeholder: String, mono: Bool = false,
        focused: FocusState<Bool>.Binding? = nil,
    ) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Text(label)
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Otty.State.header)
            textField(placeholder, text: text, mono: mono, focused: focused)
        }
    }

    /// The inset text field plate, with focus bound onto the field itself when a binding is supplied.
    @ViewBuilder
    private func textField(
        _ placeholder: String, text: Binding<String>, mono: Bool, focused: FocusState<Bool>.Binding?,
    ) -> some View {
        let field = TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(mono
                ? .system(size: Otty.Typeface.body).monospaced()
                : .system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.primary)
            .tint(Otty.State.accent)
            .padding(Otty.Metric.space2)
            .background(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .fill(Otty.Surface.element),
            )
            .onSubmit { connectAndClose() }
        if let focused {
            field.focused(focused)
        } else {
            field
        }
    }

    // MARK: - Advanced (video ports)

    @ViewBuilder private var advancedSection: some View {
        if showAdvanced {
            HStack(spacing: Otty.Metric.space3) {
                field(label: "Media Port", text: $connection.mediaPort, placeholder: "9001", mono: true)
                field(label: "Cursor Port", text: $connection.cursorPort, placeholder: "9002", mono: true)
            }
        } else {
            Button {
                showAdvanced = true
            } label: {
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemSymbol: .chevronRight)
                        .font(.system(size: Otty.Typeface.small))
                    Text("Advanced (video ports)")
                        .font(.system(size: Otty.Typeface.footnote))
                }
                .foregroundStyle(Otty.Text.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Validation hint

    /// Shown only while the form is invalid (`validationHint != nil ⟺ !canConnect`) — names why Connect is
    /// disabled (bad host / port / equal video ports).
    private func hintRow(_ hint: String) -> some View {
        HStack(spacing: Otty.Metric.space1) {
            Image(systemSymbol: .exclamationmarkTriangle)
                .font(.system(size: Otty.Typeface.small))
            Text(hint)
                .font(.system(size: Otty.Typeface.footnote))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Otty.Status.warn)
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: Otty.Metric.space2) {
            Spacer(minLength: 0)
            Button("Cancel") { coordinator.closeConnect() }
                .buttonStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)

            Button { connectAndClose() } label: {
                Text("Connect")
                    .font(.system(size: Otty.Typeface.body, weight: .semibold))
                    .foregroundStyle(connection.canConnect ? Otty.Surface.card : Otty.Text.tertiary)
                    .padding(.horizontal, Otty.Metric.space3)
                    .padding(.vertical, Otty.Metric.space1)
                    .background(
                        RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                            .fill(connection.canConnect ? Otty.State.accent : Otty.Surface.element),
                    )
            }
            .buttonStyle(.plain)
            .disabled(!connection.canConnect)
        }
    }

    // MARK: - Actions

    /// Validate-then-connect: no-op unless the form parses (the button is also disabled then), then fire the
    /// app's `connect()` and close. Never force-unwraps — `canConnect` gates here and `connect()` re-guards
    /// the parse internally.
    private func connectAndClose() {
        guard connection.canConnect else { return }
        Task {
            await connection.connect()
            coordinator.closeConnect()
        }
    }
}
#endif
